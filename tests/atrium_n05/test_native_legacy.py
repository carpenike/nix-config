"""Native SDK provenance tests; licensed JWT cryptographic HTTP permits are not mocked."""

import asyncio
import json

import pytest

pytest.importorskip("litellm")
from fastapi import HTTPException
from litellm.proxy import proxy_server
from litellm.proxy._types import UserAPIKeyAuth
from starlette.requests import Request
from test_admission import fixture as admission_fixture

from atrium_admission.hook import (
    OwnedAdmission,
    _native_non_virtual_jwt,
    _native_public,
)

fixture = admission_fixture


@pytest.fixture
def native_modes(monkeypatch):
    monkeypatch.setattr(proxy_server, "general_settings", {})
    monkeypatch.setattr(proxy_server, "premium_user", False)
    monkeypatch.setattr(proxy_server, "user_custom_auth", None)


def request(path, method="GET", body=None):
    value = Request(
        {
            "type": "http",
            "method": method,
            "path": path,
            "headers": [(b"content-type", b"application/json")],
        }
    )
    value._body = json.dumps(body or {}).encode()
    return value


def test_actual_public_branch_preserves_identity_without_initializing_state(
    native_modes,
):
    from litellm.proxy._types import LitellmUserRoles

    identity = UserAPIKeyAuth(
        user_role=LitellmUserRoles.INTERNAL_USER_VIEW_ONLY, request_route="/routes"
    )
    original = identity.model_dump()
    hook = OwnedAdmission()
    assert (
        asyncio.run(hook.async_post_native_auth(identity, request("/routes")))
        == "native-public"
    )
    assert identity.model_dump() == original
    assert hook.engine is None


def test_additional_public_routes_use_the_real_native_premium_predicate(
    native_modes, monkeypatch
):
    from litellm.proxy._types import LitellmUserRoles

    identity = UserAPIKeyAuth(
        user_role=LitellmUserRoles.INTERNAL_USER_VIEW_ONLY, request_route="/v1/models"
    )
    proxy_server.general_settings["public_routes"] = ["/v1/models"]
    assert not _native_public(identity, request("/v1/models"))
    monkeypatch.setattr(proxy_server, "premium_user", True)
    hook = OwnedAdmission()
    assert (
        asyncio.run(hook.async_post_native_auth(identity, request("/v1/models")))
        == "native-public"
    )
    assert hook.engine is None


@pytest.mark.parametrize(
    "fault",
    ["virtual", "token", "digest", "managed-metadata", "route", "role", "jwt-claims"],
)
def test_public_is_not_a_blanket_missing_key_or_role_exemption(native_modes, fault):
    from litellm.proxy._types import LitellmUserRoles

    identity = UserAPIKeyAuth(
        user_role=LitellmUserRoles.INTERNAL_USER_VIEW_ONLY, request_route="/routes"
    )
    if fault == "virtual":
        identity.via_virtual_key = True
    elif fault == "token":
        identity.token = "f" * 64
    elif fault == "digest":
        identity.api_key = "f" * 64
    elif fault == "managed-metadata":
        identity.metadata = {"cc.owner": "command-center"}
    elif fault == "route":
        identity.request_route = "/v1/chat/completions"
    elif fault == "role":
        identity.user_role = LitellmUserRoles.PROXY_ADMIN
    elif fault == "jwt-claims":
        identity.jwt_claims = {"sub": "native-subject"}
    assert not _native_public(identity, request("/routes"))


def test_public_wildcard_does_not_enable_unauthenticated_inference(
    native_modes, monkeypatch
):
    from litellm.proxy._types import LitellmUserRoles

    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["public_routes"] = ["/*"]
    for path in (
        "/v1/chat/completions",
        "/v1/messages/count_tokens",
        "/anthropic/v1/messages",
    ):
        identity = UserAPIKeyAuth(
            user_role=LitellmUserRoles.INTERNAL_USER_VIEW_ONLY, request_route=path
        )
        assert not _native_public(identity, request(path, "POST"))


def test_public_metrics_cannot_override_the_native_auth_requirement(
    native_modes, monkeypatch
):
    import litellm
    from litellm.proxy._types import LitellmUserRoles

    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["public_routes"] = ["/metrics"]
    identity = UserAPIKeyAuth(
        user_role=LitellmUserRoles.INTERNAL_USER_VIEW_ONLY, request_route="/metrics"
    )
    monkeypatch.setattr(litellm, "require_auth_for_metrics_endpoint", True)
    assert not _native_public(identity, request("/metrics"))
    monkeypatch.setattr(litellm, "require_auth_for_metrics_endpoint", False)
    assert _native_public(identity, request("/metrics"))


def jwt_identity(**values):
    return UserAPIKeyAuth(
        request_route="/v1/chat/completions",
        jwt_claims={"sub": "native-subject"},
        **values,
    )


@pytest.mark.parametrize("role", ["proxy_admin", "internal_user"])
def test_non_virtual_jwt_is_native_not_an_atrium_admin_exception(
    native_modes, monkeypatch, role
):
    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["enable_jwt_auth"] = True
    identity = jwt_identity(user_role=role)
    original = identity.model_dump()
    hook = OwnedAdmission()
    data = {"model": "native-legacy", "metadata": {"principal": "forged"}}
    assert (
        asyncio.run(
            hook.async_post_native_auth(
                identity, request("/v1/chat/completions", "POST", data)
            )
        )
        == "native-non-virtual-jwt"
    )
    assert (
        asyncio.run(hook.async_pre_call_hook(identity, None, data, "acompletion"))
        is data
    )
    assert identity.model_dump() == original and hook.engine is None


@pytest.mark.parametrize(
    "fault",
    [
        "virtual",
        "token",
        "digest",
        "managed-metadata",
        "empty-claims",
        "disabled",
        "unlicensed",
        "custom",
        "oauth",
    ],
)
def test_jwt_mapping_or_missing_provenance_never_becomes_non_owned(
    native_modes, monkeypatch, fault
):
    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["enable_jwt_auth"] = True
    identity = jwt_identity(user_role="proxy_admin")
    if fault == "virtual":
        identity.via_virtual_key = True
    elif fault == "token":
        identity.token = "f" * 64
    elif fault == "digest":
        identity.api_key = "f" * 64
    elif fault == "managed-metadata":
        identity.metadata = {"cc.template": "owned"}
    elif fault == "empty-claims":
        identity.jwt_claims = {}
    elif fault == "disabled":
        proxy_server.general_settings["enable_jwt_auth"] = False
    elif fault == "unlicensed":
        monkeypatch.setattr(proxy_server, "premium_user", False)
    elif fault == "custom":
        monkeypatch.setattr(proxy_server, "user_custom_auth", object())
    elif fault == "oauth":
        proxy_server.general_settings["enable_oauth2_auth"] = True
    assert not _native_non_virtual_jwt(identity)


@pytest.mark.parametrize("provenance", ["virtual", "mapped-token", "auth-disabled"])
def test_unresolved_virtual_and_auth_disabled_contexts_still_fail_closed(
    fixture, native_modes, monkeypatch, provenance
):
    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["enable_jwt_auth"] = provenance != "auth-disabled"
    identity = jwt_identity(user_role="proxy_admin")
    if provenance == "virtual":
        identity.via_virtual_key = True
    elif provenance == "mapped-token":
        identity.token = fixture["key"]
    else:
        identity.jwt_claims = None
        monkeypatch.setattr(proxy_server, "master_key", None)
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    with pytest.raises(HTTPException) as rejected:
        asyncio.run(
            hook.async_post_native_auth(
                identity, request("/v1/chat/completions", "POST")
            )
        )
    assert rejected.value.status_code == 503


def test_mapped_jwt_shape_uses_real_protected_deny_policy(
    fixture, native_modes, monkeypatch
):
    monkeypatch.setattr(proxy_server, "premium_user", True)
    proxy_server.general_settings["enable_jwt_auth"] = True
    identity = jwt_identity(api_key=fixture["key"], team_id="native-family")
    identity.via_virtual_key = True
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    data = {"model": "cc.family.text"}
    assert (
        asyncio.run(hook.async_pre_call_hook(identity, None, data, "acompletion"))
        is data
    )
    fixture["raw"].update(generation=2, deny=("fixture-child",))
    fixture["engine"].feed.poll(force=True)
    with pytest.raises(HTTPException) as denied:
        asyncio.run(hook.async_pre_call_hook(identity, None, data, "acompletion"))
    assert denied.value.status_code == 403
