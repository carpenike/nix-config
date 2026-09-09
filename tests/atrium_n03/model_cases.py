"""Small actual-HTTP topology pairs, called only by a later authorized native lane."""

import hashlib
import json
import time
from collections.abc import Callable, Mapping
from typing import Any, Protocol
from urllib.parse import urlsplit


class Client(Protocol):
    def call(self, action: str, **fields: object) -> dict[str, Any]: ...


Counts = Callable[[], Mapping[str, Any]]


def require_native_assignment(fixture: dict[str, Any]) -> None:
    if (
        not fixture["modelPlaneReady"]
        or fixture["models"]["acceptedPublisherPins"] is None
        or any(
            not (urlsplit(url).hostname or "").endswith(".atrium.invalid")
            for url in fixture["endpoints"].values()
        )
    ):
        raise RuntimeError("model_preparation_has_no_native_authorization")


def inference(client: Client, endpoint: str, key: str, model: str) -> dict[str, Any]:
    return client.call(
        "request",
        method="POST",
        url=endpoint + "/v1/chat/completions",
        headers={"Authorization": "Bearer " + key},
        body={
            "model": model,
            "messages": [{"role": "user", "content": "Synthetic N03 topology read."}],
            "max_tokens": 8,
            "stream": False,
        },
    )


def public_pairs(
    fixture: dict[str, Any],
    client: Client,
    key: str,
    permitted_model: str,
    foreign_model: str,
    observe: Counts,
    backend_address: str,
    expected_account: str,
) -> dict[str, Any]:
    """The caller supplies a real R03/R06 delivery and actual N07 provider observer."""
    require_native_assignment(fixture)
    assert permitted_model != foreign_model
    endpoint = fixture["endpoints"]["models"]
    before = observe()
    permitted = inference(client, endpoint, key, permitted_model)
    assert permitted["status"] == 200, "model_permit_required"
    assert json.loads(permitted["body"])["choices"][0]["message"]["content"]
    after = observe()
    assert (
        after["accounts"][expected_account]["authorized"]
        > before["accounts"][expected_account]["authorized"]
    ), "intended_provider_account_permit_required"
    assert all(
        counters == before["accounts"][account]
        for account, counters in after["accounts"].items()
        if account != expected_account
    ), "permit_reached_another_provider_account"
    before = observe()
    rejected = inference(client, endpoint, key, foreign_model)
    assert rejected["status"] in (401, 403), "wrong_model_was_not_refused"
    wrong_target = client.call(
        "request",
        method="POST",
        url=fixture["endpoints"]["native"] + "/mcp",
        headers={"Authorization": "Bearer " + key},
        body={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    )
    assert wrong_target["status"] == 401, "wrong_target_was_not_refused"
    management = client.call(
        "request",
        method="POST",
        url=endpoint + "/key/generate",
        headers={"Authorization": "Bearer " + key},
        body={"models": [permitted_model]},
    )
    assert management["status"] in (401, 403), "inference_key_reached_management"
    assert not client.call(
        "connect", address=backend_address, port=fixture["models"]["port"]
    )["connected"], "model_backend_reachable_from_untrusted_client"
    assert observe() == before, "denied_model_request_changed_provider_effects"
    return {
        "case": "model-public-permit-wrong-model-target-and-direct-backend",
        "status": "passed",
        "permits": [200],
        "denials": [rejected["status"], 401, management["status"], "socket-refused"],
        "denial_effects_unchanged": True,
    }


def known_deny_pair(
    fixture: dict[str, Any],
    client: Client,
    key: str,
    model: str,
    administrator: str,
    observe: Counts,
) -> dict[str, Any]:
    require_native_assignment(fixture)
    endpoint = fixture["endpoints"]["models"]
    assert inference(client, endpoint, key, model)["status"] == 200
    identifier = "sha256:" + hashlib.sha256(key.encode()).hexdigest()

    def publish(method: str) -> None:
        response = client.call(
            "request",
            method=method,
            url=fixture["endpoints"]["resolver"] + "/v1/denies",
            headers={"Authorization": "Bearer " + administrator},
            body={"kind": "credential", "issuer": endpoint, "identifier": identifier},
        )
        assert response["status"] == 200, "real_model_deny_administration_required"

    def wait(expected: int) -> float:
        started = time.monotonic()
        while time.monotonic() - started < 60:
            response = inference(client, endpoint, key, model)
            if response["status"] == expected:
                return round(time.monotonic() - started, 3)
            time.sleep(1)
        raise AssertionError("model_deny_or_recovery_deadline_missed")

    publish("POST")
    try:
        propagation = wait(403)
        before = observe()
        assert inference(client, endpoint, key, model)["status"] == 403
        assert observe() == before, "known_denied_model_reached_provider"
    finally:
        publish("DELETE")
    wait(200)
    return {
        "case": "real-model-key-r07-known-deny-and-recovery",
        "status": "passed",
        "permits": [200, 200],
        "denials": [403],
        "denial_effects_unchanged": True,
        "healthy_propagation_seconds": propagation,
    }
