import atexit
import logging
import os
import threading
import time
from hashlib import sha256
from pathlib import Path

from atrium_profiles import ProfileError
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from starlette.concurrency import run_in_threadpool

from .cli import load_settings
from .engine import Admission
from .models import AdmissionError

logger = logging.getLogger(__name__)

INFERENCE_CALLS = {
    f"{prefix}/{route}": call_type
    for prefix in ("", "/v1")
    for route, call_type in (
        ("chat/completions", "acompletion"),
        ("completions", "atext_completion"),
        ("embeddings", "aembedding"),
        ("responses", "aresponses"),
        ("messages", "anthropic_messages"),
    )
}


def _native_key_hash(identity):
    from litellm.constants import LITELLM_PROXY_MASTER_KEY_ALIAS
    from litellm.proxy._types import LitellmUserRoles

    native_id = getattr(identity, "api_key", None)
    if native_id != LITELLM_PROXY_MASTER_KEY_ALIAS:
        return native_id
    from litellm.proxy.proxy_server import master_key

    if (
        getattr(identity, "via_virtual_key", False) is not True
        or getattr(identity, "user_role", None) != LitellmUserRoles.PROXY_ADMIN
        or not isinstance(master_key, str)
        or not master_key
    ):
        raise AdmissionError("native_control_identity_unavailable", 503)
    # Native auth replaces the verified master with a reserved alias. Resolve it
    # privately for ownership checks; never change the identity used by native logs.
    return sha256(master_key.encode()).hexdigest()


def _native_unkeyed(identity):
    from litellm.proxy._types import UserAPIKeyAuth

    metadata = getattr(identity, "metadata", None)
    return (
        isinstance(identity, UserAPIKeyAuth)
        and getattr(identity, "api_key", None) is None
        and getattr(identity, "token", None) is None
        and getattr(identity, "via_virtual_key", None) is False
        and (metadata is None or isinstance(metadata, dict))
        and not any(str(name).startswith("cc.") for name in metadata or {})
    )


def _native_public(identity, connection):
    from litellm.proxy._types import LiteLLMRoutes, LitellmUserRoles
    from litellm.proxy.auth.auth_utils import (
        get_request_route,
        normalize_request_route,
        route_in_additonal_public_routes,
    )
    from litellm.proxy.auth.route_checks import RouteChecks
    from litellm.proxy.auth.user_api_key_auth import _route_requires_auth_despite_public
    from litellm.proxy.proxy_server import general_settings

    if (
        not _native_unkeyed(identity)
        or getattr(identity, "jwt_claims", None) is not None
        or identity.user_role != LitellmUserRoles.INTERNAL_USER_VIEW_ONLY
        or connection.scope.get("type") != "http"
        or not isinstance(connection.scope.get("path"), str)
    ):
        return False
    route = get_request_route(connection)
    if not route.startswith("/") or normalize_request_route(route) != getattr(
        identity, "request_route", None
    ):
        return False
    # Discovery can be native-public; a public wildcard must not create an
    # unauthenticated inference path through the owned gateway.
    if RouteChecks.is_llm_api_route(route) and not (
        route in ("/models", "/v1/models")
        and connection.scope.get("method") in ("GET", "HEAD")
    ):
        return False
    return not _route_requires_auth_despite_public(route, general_settings) and (
        route in LiteLLMRoutes.public_routes.value
        or route_in_additonal_public_routes(current_route=route)
    )


def _native_non_virtual_jwt(identity):
    from litellm.proxy import proxy_server

    settings = proxy_server.general_settings
    return (
        _native_unkeyed(identity)
        and isinstance(getattr(identity, "jwt_claims", None), dict)
        and bool(identity.jwt_claims)
        and isinstance(getattr(identity, "request_route", None), str)
        and isinstance(settings, dict)
        and settings.get("enable_jwt_auth") is True
        and proxy_server.premium_user is True
        and proxy_server.user_custom_auth is None
        and settings.get("enable_oauth2_auth") is not True
        and settings.get("enable_oauth2_proxy_auth") is not True
    )


class OwnedAdmission(CustomLogger):
    def __init__(self):
        super().__init__(turn_off_message_logging=True)
        self.engine = None
        self._lock = threading.Lock()
        self._last_now = 0

    def _engine(self):
        with self._lock:
            if self.engine is None:
                settings = load_settings(Path(os.environ["ATRIUM_ADMISSION_SETTINGS"]))
                self.engine = Admission(settings)
                atexit.register(self.engine.close)
            return self.engine

    def _observed_engine(self, observed):
        with self._lock:
            self._last_now = max(self._last_now, observed)
        engine = self._engine()
        with self._lock:
            minimum = self._last_now
        engine.store.observe_clock(minimum=minimum)
        return engine

    async def _admit(self, user_api_key_dict, model, path):
        if _native_non_virtual_jwt(user_api_key_dict):
            # Native JWT policy already ran. This is not Atrium principal
            # mapping or its administrator freshness exception.
            return "native-non-virtual-jwt"
        observed = int(time.time())
        try:
            engine = await run_in_threadpool(self._observed_engine, observed)
            return await run_in_threadpool(
                engine.admit,
                _native_key_hash(user_api_key_dict),
                getattr(user_api_key_dict, "team_id", None),
                model,
                path,
            )
        except AdmissionError as error:
            raise HTTPException(status_code=error.status, detail=error.code) from None
        except ProfileError as error:
            raise HTTPException(status_code=403, detail=error.code) from None
        except Exception:
            raise HTTPException(
                status_code=503, detail="admission_unavailable"
            ) from None

    async def async_post_native_auth(self, user_api_key_dict, connection):
        from litellm.proxy.common_utils.http_parsing_utils import _read_request_body

        if _native_public(user_api_key_dict, connection):
            return "native-public"
        route = getattr(user_api_key_dict, "request_route", None)
        model, path = None, None
        if (
            connection.scope["type"] == "http"
            and connection.scope.get("method") == "POST"
            and isinstance(route, str)
            and route in INFERENCE_CALLS
        ):
            data = await _read_request_body(connection)
            model = data.get("model") if isinstance(data, dict) else None
            path = route
        return await self._admit(user_api_key_dict, model, path)

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Native auth stamps this from ASGI scope; raw passthrough body fields
        # named proxy_server_request are not authenticated transport context.
        route = getattr(user_api_key_dict, "request_route", None)
        path = (
            route
            if isinstance(route, str)
            and route in INFERENCE_CALLS
            and INFERENCE_CALLS[route] == call_type
            else None
        )
        await self._admit(
            user_api_key_dict,
            data.get("model") if isinstance(data, dict) else None,
            path,
        )
        return data

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        # Native 1.99.1 awaits this even when authentication rejects before admission.
        observed = int(time.time())
        try:
            await run_in_threadpool(self._observed_engine, observed)
        except (AdmissionError, ProfileError, OSError, KeyError, ValueError):
            logger.error("admission_failure_clock_unavailable")
        return None


admission = OwnedAdmission()
