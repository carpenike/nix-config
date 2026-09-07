"""Focused callback tests; native HTTP coverage lives in context_cases.py."""

import asyncio

import pytest
from fastapi import HTTPException
from test_admission import fixture as admission_fixture

pytest.importorskip("litellm")
from litellm.proxy._types import UserAPIKeyAuth
from litellm.proxy.auth.auth_utils import normalize_request_route

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
