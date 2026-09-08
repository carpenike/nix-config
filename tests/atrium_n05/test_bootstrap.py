"""Dependency graph/signature checks; native HTTP tests never replace authentication."""

import asyncio
import inspect

import pytest

pytest.importorskip("litellm")
from fastapi import Depends, FastAPI
from fastapi.dependencies.utils import get_typed_signature
from litellm.proxy._types import UserAPIKeyAuth
from litellm.proxy.auth.user_api_key_auth import (
    user_api_key_auth,
    user_api_key_auth_websocket,
)

from atrium_admission.bootstrap import _release_reservation, _signature, install
from atrium_admission.hook import OwnedAdmission


@pytest.fixture
def app():
    application = FastAPI()

    async def unused_endpoint():
        raise AssertionError("This unit fixture never sends HTTP requests")

    for path in ("/v1/messages/count_tokens", "/v1/chat/completions"):
        application.add_api_route(
            path,
            unused_endpoint,
            methods=["POST"],
            dependencies=[Depends(user_api_key_auth)],
        )
    application.add_api_websocket_route(
        "/v1/responses",
        unused_endpoint,
        dependencies=[Depends(user_api_key_auth_websocket)],
    )
    return application


def test_installer_preserves_native_signature_security_and_originals(app):
    adapter = OwnedAdmission()
    coverage = asyncio.run(install(app=app, adapter=adapter))
    assert "/v1/messages/count_tokens" in coverage["request"]
    assert "/v1/responses" in coverage["websocket"]
    for original in (user_api_key_auth, user_api_key_auth_websocket):
        wrapper = app.dependency_overrides[original]
        assert wrapper.__wrapped__ is original
        assert (
            get_typed_signature(wrapper).parameters == _signature(original).parameters
        )
        assert inspect.signature(wrapper) == _signature(original)
        assert all(
            parameter.default is inspect.signature(original).parameters[name].default
            for name, parameter in inspect.signature(wrapper).parameters.items()
        )
        assert all(
            getattr(parameter.default, "dependency", None) is not original
            for parameter in inspect.signature(wrapper).parameters.values()
        )
    assert asyncio.run(install(app=app, adapter=adapter)) == coverage


def test_installer_refuses_existing_or_replaced_auth_overrides(app):
    app.dependency_overrides[user_api_key_auth] = user_api_key_auth
    with pytest.raises(RuntimeError, match="already_overridden"):
        asyncio.run(install(app=app, adapter=OwnedAdmission()))
    app.dependency_overrides.clear()
    adapter = OwnedAdmission()
    asyncio.run(install(app=app, adapter=adapter))
    app.dependency_overrides[user_api_key_auth] = user_api_key_auth
    with pytest.raises(RuntimeError, match="installation_changed"):
        asyncio.run(install(app=app, adapter=adapter))


def test_installer_refuses_a_different_adapter_or_missing_required_route(app):
    asyncio.run(install(app=app, adapter=OwnedAdmission()))
    with pytest.raises(RuntimeError, match="installation_changed"):
        asyncio.run(install(app=app, adapter=OwnedAdmission()))
    with pytest.raises(RuntimeError, match="dependency_missing"):
        asyncio.run(install(app=FastAPI(), adapter=OwnedAdmission()))


def test_denied_request_uses_native_reservation_refund():
    identity = UserAPIKeyAuth(
        budget_reservation={"reserved_cost": 1.0, "entries": [], "finalized": False}
    )
    asyncio.run(_release_reservation(identity))
    assert identity.budget_reservation["finalized"] is True


def test_installer_matches_the_actual_pinned_application_graph():
    from litellm.proxy.proxy_server import app as native_app

    overrides = dict(native_app.dependency_overrides)
    try:
        coverage = asyncio.run(install(app=native_app, adapter=OwnedAdmission()))
        assert "/v1/messages/count_tokens" in coverage["request"]
        assert "/v1/responses" in coverage["websocket"]
    finally:
        native_app.dependency_overrides.clear()
        native_app.dependency_overrides.update(overrides)
        if hasattr(native_app.state, "atrium_post_native_auth"):
            del native_app.state.atrium_post_native_auth
