import copy
import json
import secrets
from urllib.request import Request

import httpx
import pytest

from atrium_litellm.errors import ControllerError
from atrium_litellm.native import Native, NativeError
from readback_controller import ControllerReadbackOpener, isolated_desired


def test_controller_fixture_keeps_generated_policy_and_uses_disjoint_aliases(generated):
    before = copy.deepcopy(generated)
    desired = isolated_desired(generated, "fixture")
    assert generated == before
    assert set(desired.aliases) == set(desired.teams) == {"cc.readback.fixture"}
    assert desired.aliases["cc.readback.fixture"]["domain"] == "personal:ryan"
    assert desired.document["ownership"] == generated["ownership"]
    assert desired.templates == {}


@pytest.mark.parametrize("delete", [False, True])
@pytest.mark.parametrize("status", [200, 403])
def test_controller_transport_preserves_requests_and_observed_worker_switch(
    delete, status
):
    key = "sk-" + secrets.token_urlsafe(32)
    master = "sk-" + secrets.token_urlsafe(32)
    payload = {
        "credential_name": "cc.fixture",
        "credential_info": {"cc.account": "fixture"},
        "credential_values": {"api_key": secrets.token_urlsafe(32)},
    }
    calls = []
    present = False

    def respond(pid, request):
        nonlocal present
        calls.append((pid, request.method, request.url.path))
        assert request.headers["authorization"] == "Bearer " + (
            master if request.method == "DELETE" else key
        )
        if request.method == "POST":
            assert json.loads(request.content) == payload
            present = True
        elif request.method == "DELETE":
            present = False
        return httpx.Response(
            status if request.method == "GET" else 200,
            json={"success": True, "credentials": [payload] if present else []},
            headers={
                "x-atrium-readback-pid": str(pid),
                "x-atrium-readback-poll": "30",
                "x-atrium-readback-redis": "0",
            },
        )

    endpoint = "http://models.atrium.invalid"
    with (
        httpx.Client(
            base_url=endpoint,
            transport=httpx.MockTransport(lambda request: respond(101, request)),
        ) as writer,
        httpx.Client(
            base_url=endpoint,
            transport=httpx.MockTransport(lambda request: respond(102, request)),
        ) as reader,
    ):
        result = {}
        native = Native(endpoint, key)
        native.opener = ControllerReadbackOpener(
            {101: writer, 102: reader},
            101,
            102,
            master,
            result,
            lambda: None,
            delete=delete,
        )
        native.call("POST", "/credentials", payload)
        for _ in range(2):
            if status == 403:
                with pytest.raises(NativeError) as refused:
                    native.credentials(timeout=1)
                assert refused.value.status == 403
            else:
                native.credentials(timeout=1)
        assert result["readbacks"][0]["pid"] == 101
        assert result["readbacks"][1]["pid"] == 102
        assert "credential_values" not in json.dumps(result)
        assert payload["credential_values"]["api_key"] not in json.dumps(result)
        assert key not in json.dumps(result) and master not in json.dumps(result)
        with pytest.raises(
            ControllerError, match="controller_repeated_credential_post"
        ):
            native.call("POST", "/credentials", payload)
        assert calls == [
            (101, "POST", "/credentials"),
            (101, "GET", "/credentials"),
            *([(102, "DELETE", "/credentials/cc.fixture")] if delete else []),
            (102, "GET", "/credentials"),
        ]


@pytest.mark.parametrize(
    ("method", "endpoint"),
    [
        ("POST", "http://models.atrium.invalid/v1/chat/completions"),
        ("GET", "http://foreign.atrium.invalid/credentials"),
    ],
)
def test_controller_probe_never_broadens_native_routes(method, endpoint):
    with httpx.Client(base_url="http://models.atrium.invalid") as client:
        opener = ControllerReadbackOpener(
            {101: client}, 101, 101, "sk-" + secrets.token_urlsafe(32), {}, lambda: None
        )
        with pytest.raises(ControllerError, match="controller_probe_route_forbidden"):
            opener.open(Request(endpoint, method=method), timeout=1)
