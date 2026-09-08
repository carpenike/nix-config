"""Install post-native-auth admission through pinned LiteLLM's worker startup hook."""

import asyncio
import inspect
import logging
from functools import wraps
from importlib.metadata import version
from typing import get_type_hints

from fastapi import HTTPException, WebSocketException

logger = logging.getLogger(__name__)


async def _release_reservation(identity):
    reservation = getattr(identity, "budget_reservation", None)
    if reservation is None:
        return
    from litellm.proxy.spend_tracking.budget_reservation import (
        release_budget_reservation,
    )

    try:
        await asyncio.shield(release_budget_reservation(reservation))
    except (Exception, asyncio.CancelledError):
        logger.error("post_native_auth_budget_release_failed")


def _signature(original):
    signature = inspect.signature(original)
    annotations = get_type_hints(inspect.unwrap(original))
    return signature.replace(
        parameters=[
            parameter.replace(annotation=annotations.get(name, parameter.annotation))
            for name, parameter in signature.parameters.items()
        ],
        return_annotation=annotations.get("return", signature.return_annotation),
    )


def _wrapper(original, adapter, connection_name):
    signature = _signature(original)

    @wraps(original)
    async def guarded(*args, **kwargs):
        identity = await original(*args, **kwargs)
        connection = signature.bind(*args, **kwargs).arguments[connection_name]
        try:
            await adapter.async_post_native_auth(identity, connection)
        except BaseException as error:
            await _release_reservation(identity)
            if (
                isinstance(error, HTTPException)
                and connection.scope["type"] == "websocket"
            ):
                raise WebSocketException(code=1008, reason=error.detail) from None
            raise
        return identity

    # FastAPI must resolve real types, not copied forward references in this
    # module's globals. Security defaults remain the original objects.
    guarded.__signature__ = signature
    guarded.__annotations__ = {
        name: parameter.annotation
        for name, parameter in signature.parameters.items()
        if parameter.annotation is not inspect.Parameter.empty
    }
    if signature.return_annotation is not inspect.Signature.empty:
        guarded.__annotations__["return"] = signature.return_annotation
    return guarded


def _uses(dependant, original):
    return dependant.call is original or any(
        _uses(child, original) for child in dependant.dependencies
    )


async def install(*, app=None, adapter=None):
    if version("litellm") != "1.99.1":
        raise RuntimeError("unsupported_litellm_version")
    from litellm.proxy.auth.user_api_key_auth import (
        user_api_key_auth,
        user_api_key_auth_websocket,
    )

    if app is None:
        from litellm.proxy.proxy_server import app
    if adapter is None:
        from .hook import admission as adapter

    originals = {
        user_api_key_auth: "request",
        user_api_key_auth_websocket: "websocket",
    }
    previous = getattr(app.state, "atrium_post_native_auth", None)
    if previous is not None:
        if previous["adapter"] is not adapter or any(
            app.dependency_overrides.get(original) is not wrapper
            for original, wrapper in previous["wrappers"].items()
        ):
            raise RuntimeError("post_native_auth_installation_changed")
        return previous["coverage"]
    if any(original in app.dependency_overrides for original in originals):
        raise RuntimeError("native_auth_dependency_already_overridden")
    if not any(
        getattr(route, "path", None) == "/v1/messages/count_tokens"
        for route in app.routes
    ):
        # 1.99.1 advertises this router lazily. Use the same loader as its
        # middleware and /lazy/warm, then inspect the real registered dependency.
        from litellm.proxy._lazy_features import LAZY_FEATURES, _force_load

        feature = next(
            feature
            for feature in LAZY_FEATURES
            if feature.name == "anthropic_passthrough"
        )
        if not await _force_load(app, feature):
            raise RuntimeError("native_token_count_router_unavailable")
    coverage = {
        connection: sorted(
            {
                route.path
                for route in app.routes
                if getattr(route, "dependant", None) is not None
                and _uses(route.dependant, original)
            }
        )
        for original, connection in originals.items()
    }
    if not {"/v1/messages/count_tokens", "/v1/chat/completions"} <= set(
        coverage["request"]
    ):
        raise RuntimeError("required_native_auth_dependency_missing")
    wrappers = {
        original: _wrapper(original, adapter, connection)
        for original, connection in originals.items()
    }
    app.dependency_overrides.update(wrappers)
    app.state.atrium_post_native_auth = {
        "adapter": adapter,
        "wrappers": wrappers,
        "coverage": coverage,
    }
    return coverage
