import hashlib
import secrets
import threading
from http.server import ThreadingHTTPServer

import httpx
import pytest

from native_runner import MARKER, content
from provider import handler


@pytest.fixture
def fixture_provider():
    inference, observer = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(inference, observer))
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with httpx.Client(
            base_url=f"http://127.0.0.1:{server.server_port}", trust_env=False
        ) as client:
            yield (
                client,
                {"Authorization": "Bearer " + inference},
                {"Authorization": "Bearer " + observer},
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        assert not thread.is_alive()


@pytest.mark.parametrize("stream", [False, True])
def test_non_actuating_provider_supports_real_stream_payloads(fixture_provider, stream):
    client, inference, observer = fixture_provider
    response = client.post(
        "/v1/chat/completions",
        headers=inference,
        json={
            "model": "fixture-family",
            "stream": stream,
            "messages": [{"role": "user", "content": "fixture only"}],
        },
    )
    assert response.status_code == 200 and content(response, stream) == MARKER
    state = client.get("/_probe/state", headers=observer).json()
    assert state["provider"]["received"] == state["provider"]["authorized"] == 1
    assert state["events"] == []


def test_fixture_deny_control_requires_observer_credential(fixture_provider):
    client, inference, observer = fixture_provider
    key_hash = hashlib.sha256(b"synthetic identity").hexdigest()
    body = {"key_sha256": key_hash, "deny": True}
    assert client.post("/_probe/deny", json=body).status_code == 401
    assert client.post("/_probe/deny", headers=inference, json=body).status_code == 401
    assert client.post("/_probe/deny", headers=observer, json=body).status_code == 200
    event = {
        "key_sha256": key_hash,
        "pid": 123,
        "context_type": "UserAPIKeyAuth",
        "native_principal": "fixture-n05",
        "native_team": None,
        "call_type": "acompletion",
    }
    assert client.post("/_probe/check", headers=observer, json=event).json() == {
        "deny": True
    }
    client.post("/_probe/deny", headers=observer, json=body | {"deny": False})
    assert client.post("/_probe/check", headers=observer, json=event).json() == {
        "deny": False
    }
    assert client.get("/_fixture/counts", headers=observer).json()["received"] == 0


@pytest.mark.parametrize(
    "changes",
    [{"key_sha256": "not-a-digest"}, {"context_type": "ClientLabel"}, {"pid": "123"}],
)
def test_observer_refuses_malformed_instrumentation(fixture_provider, changes):
    client, _, observer = fixture_provider
    response = client.post(
        "/_probe/check",
        headers=observer,
        json={
            "key_sha256": "0" * 64,
            "pid": 123,
            "context_type": "UserAPIKeyAuth",
            **changes,
        },
    )
    assert response.status_code == 400
    assert client.get("/_probe/state", headers=observer).json()["events"] == []


@pytest.mark.parametrize(
    "kind,stream",
    [
        ("embeddings", False),
        ("completions", False),
        ("completions", True),
        ("responses", False),
        ("responses", True),
    ],
)
def test_extended_provider_protocol_shapes(fixture_provider, kind, stream):
    from protocol_cases import output_present

    client, inference, observer = fixture_provider
    response = client.post(
        "/v1/" + kind,
        headers=inference,
        json={
            "model": "fixture-family",
            "stream": stream,
            "input": "fixture",
            "prompt": "fixture",
        },
    )
    assert output_present(response, kind, stream)
    assert client.get("/_fixture/counts", headers=observer).json()["authorized"] == 1
