"""Focused callback tests; native HTTP coverage lives in context_cases.py."""

import asyncio
import json

import pytest
from fastapi import HTTPException
from test_admission import fixture as admission_fixture

pytest.importorskip("litellm")
from litellm.proxy._types import UserAPIKeyAuth
from litellm.proxy.auth.auth_utils import normalize_request_route
from litellm.constants import LITELLM_PROXY_MASTER_KEY_ALIAS
from starlette.requests import Request

from atrium_admission.hook import INFERENCE_CALLS, OwnedAdmission

fixture = admission_fixture


def invoke(f, *, key=None, route="/v1/chat/completions", data=None, call="acompletion"):
    hook = OwnedAdmission()
    hook.engine = f["engine"]
    native = UserAPIKeyAuth(
        api_key=key or f["key"], team_id="native-family", request_route=route
    )
    return asyncio.run(hook.async_pre_call_hook(native, None, data, call))


@pytest.mark.parametrize("path", sorted(INFERENCE_CALLS))
def test_pinned_normalization_preserves_exact_inference_template_paths(path):
    assert normalize_request_route(path) == path


def test_native_route_not_body_transport_selects_the_owned_route(fixture):
    body = {
        "model": "cc.family.text",
        "proxy_server_request": {"method": "GET", "url": "http://forged/key/generate"},
        "request_route": "/anthropic/v1/messages",
        "metadata": {"principal": "forged-admin", "native_owned": False},
    }
    assert invoke(fixture, data=body) is body
    with pytest.raises(HTTPException) as denied:
        invoke(fixture, route="/anthropic/v1/messages", data=body)
    assert denied.value.status_code == 403


@pytest.mark.parametrize(
    "route,call,data",
    [
        (None, "pass_through_endpoint", {}),
        (None, "_arealtime", {"websocket": object()}),
        (
            "/anthropic/v1/messages",
            "pass_through_endpoint",
            {"model": "cc.family.text"},
        ),
        ("/v1/chat/completions", "acompletion", {"model": ["cc.family.text"]}),
        ("/v1/chat/completions", "acompletion", None),
        ("/v1/responses", "_aresponses_websocket", {"model": "cc.family.text"}),
        ("/v1/chat/completions", None, {"model": "cc.family.text"}),
    ],
)
def test_unsupported_shapes_deny_only_owned_after_ownership_verification(
    fixture, route, call, data
):
    assert invoke(fixture, key="f" * 64, route=route, data=data, call=call) is data
    with pytest.raises(HTTPException) as denied:
        invoke(fixture, route=route, data=data, call=call)
    assert denied.value.status_code == 403
    assert denied.value.detail == "owned_request_context_unsupported"
    fixture["primary"].unlink()
    with pytest.raises(HTTPException) as unknown:
        invoke(fixture, key="f" * 64, route=route, data=data, call=call)
    assert unknown.value.status_code == 503
    assert unknown.value.detail == "ownership_unverified"


def test_a_differently_prefixed_native_route_is_not_a_template_match(fixture):
    with pytest.raises(HTTPException) as denied:
        invoke(fixture, route="/chat/completions", data={"model": "cc.family.text"})
    assert denied.value.detail == "owned_request_not_permitted"


def test_forged_transport_does_not_turn_raw_passthrough_into_owned_inference(fixture):
    data = {
        "model": "cc.family.text",
        "proxy_server_request": {
            "method": "POST",
            "url": "http://forged/v1/chat/completions",
        },
        "request_route": "/v1/chat/completions",
        "call_type": "acompletion",
        "metadata": {"principal": "forged-admin", "native_owned": False},
    }
    with pytest.raises(HTTPException) as denied:
        invoke(
            fixture,
            route="/anthropic/v1/messages",
            call="pass_through_endpoint",
            data=data,
        )
    assert denied.value.status_code == 403
    assert denied.value.detail == "owned_request_context_unsupported"
    assert (
        invoke(
            fixture,
            key="f" * 64,
            route="/anthropic/v1/messages",
            call="pass_through_endpoint",
            data=data,
        )
        is data
    )


@pytest.mark.parametrize(
    "method,route",
    [
        ("POST", "/v1/messages/count_tokens"),
        ("GET", "/v1/responses"),
        ("POST", "/anthropic/v1/messages"),
    ],
)
def test_post_native_gate_applies_ownership_before_unsupported_context(
    fixture, method, route
):
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    request = Request({"type": "http", "method": method, "path": route, "headers": []})
    owned = UserAPIKeyAuth(
        api_key=fixture["key"], team_id="native-family", request_route=route
    )
    legacy = UserAPIKeyAuth(api_key="f" * 64, request_route=route)
    assert (
        asyncio.run(hook.async_post_native_auth(legacy, request))
        == "verified-non-owned"
    )
    with pytest.raises(HTTPException) as denied:
        asyncio.run(hook.async_post_native_auth(owned, request))
    assert denied.value.detail == "owned_request_context_unsupported"
    fixture["primary"].unlink()
    with pytest.raises(HTTPException) as unknown:
        asyncio.run(hook.async_post_native_auth(legacy, request))
    assert unknown.value.status_code == 503


def test_post_native_gate_permits_only_protected_model_and_native_route(fixture):
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    native = UserAPIKeyAuth(
        api_key=fixture["key"],
        team_id="native-family",
        request_route="/v1/chat/completions",
    )
    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/v1/chat/completions",
            "headers": [(b"content-type", b"application/json")],
        }
    )
    request._body = json.dumps(
        {
            "model": "cc.family.text",
            "proxy_server_request": {
                "method": "GET",
                "url": "http://forged/key/generate",
            },
        }
    ).encode()
    assert asyncio.run(hook.async_post_native_auth(native, request)) == "fresh"
    native.request_route = "/v1/messages/count_tokens"
    with pytest.raises(HTTPException):
        asyncio.run(hook.async_post_native_auth(native, request))


def test_native_master_alias_uses_trusted_control_identity_not_a_role_exemption(
    fixture, monkeypatch
):
    import hashlib
    import secrets
    from litellm.proxy import proxy_server
    from litellm.proxy._types import LitellmUserRoles
    from atrium_profiles.runtime import atomic_private_write

    master = "sk-" + secrets.token_urlsafe(32)
    monkeypatch.setattr(proxy_server, "master_key", master)
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    native = UserAPIKeyAuth(
        api_key=LITELLM_PROXY_MASTER_KEY_ALIAS,
        user_role="proxy_admin",
        via_virtual_key=True,
        request_route="/v1/models",
    )
    native.via_virtual_key = True
    assert native.user_role == LitellmUserRoles.PROXY_ADMIN
    assert proxy_server.master_key == master
    assert native.api_key == LITELLM_PROXY_MASTER_KEY_ALIAS
    request = Request(
        {"type": "http", "method": "GET", "path": "/v1/models", "headers": []}
    )
    assert (
        asyncio.run(hook.async_post_native_auth(native, request))
        == "verified-non-owned"
    )
    assert native.api_key == LITELLM_PROXY_MASTER_KEY_ALIAS
    master_hash = hashlib.sha256(master.encode()).hexdigest()
    with fixture["engine"].store.transaction() as state:
        assert master_hash not in state["history"]

    fixture["record"].update(
        native_key_id=master_hash, credential_id="sha256:" + master_hash
    )
    fixture["documents"]["resolver"]["generation"] += 1
    fixture["publish"]()
    with pytest.raises(HTTPException) as owned:
        asyncio.run(hook.async_post_native_auth(native, request))
    assert owned.value.status_code == 403

    ordinary_admin = UserAPIKeyAuth(
        api_key=master_hash, user_role="proxy_admin", request_route="/v1/models"
    )
    with pytest.raises(HTTPException) as scoped:
        asyncio.run(hook.async_post_native_auth(ordinary_admin, request))
    assert scoped.value.status_code == 403
    assert native.api_key == LITELLM_PROXY_MASTER_KEY_ALIAS

    atomic_private_write(fixture["primary"], b"invalid")
    with pytest.raises(HTTPException) as unavailable:
        asyncio.run(hook.async_post_native_auth(native, request))
    assert unavailable.value.status_code == 503


@pytest.mark.parametrize(
    "role,provenance,has_master",
    [
        ("internal_user", True, True),
        ("proxy_admin", False, True),
        ("proxy_admin", True, False),
    ],
)
def test_master_alias_requires_native_provenance_and_runtime_identity(
    fixture, monkeypatch, role, provenance, has_master
):
    import secrets
    from litellm.proxy import proxy_server

    master = "sk-" + secrets.token_urlsafe(32) if has_master else None
    monkeypatch.setattr(proxy_server, "master_key", master)
    hook = OwnedAdmission()
    hook.engine = fixture["engine"]
    native = UserAPIKeyAuth(
        api_key=LITELLM_PROXY_MASTER_KEY_ALIAS,
        user_role=role,
        via_virtual_key=provenance,
        request_route="/v1/models",
    )
    native.via_virtual_key = provenance
    request = Request(
        {"type": "http", "method": "GET", "path": "/v1/models", "headers": []}
    )
    with pytest.raises(HTTPException) as rejected:
        asyncio.run(hook.async_post_native_auth(native, request))
    assert rejected.value.status_code == 503
    assert rejected.value.detail == "native_control_identity_unavailable"
