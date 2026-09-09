"""Small actual-HTTP topology pairs, called only by a later authorized native lane."""

import hashlib
import json
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any, Protocol
from urllib.parse import urlsplit


class Client(Protocol):
    def call(self, action: str, **fields: object) -> dict[str, Any]: ...


Counts = Callable[[], Mapping[str, Any]]
NativeObservation = Callable[[str], Mapping[str, Any]]


@dataclass(frozen=True)
class ModelDelivery:
    token: str = field(repr=False)
    target: str
    expires_at: int


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


def inference(
    client: Client, endpoint: str, key: str, model: str, *, target: str | None = None
) -> dict[str, Any]:
    return client.call(
        "request",
        method="POST",
        url=target or endpoint + "/v1/chat/completions",
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


def model_delivery(
    fixture: dict[str, Any],
    client: Client,
    owner_identity: str,
    instance_id: str,
) -> ModelDelivery:
    """Use the public R03 references and real R06 one-use delivery, never a control key."""
    require_native_assignment(fixture)
    instance = fixture["generated"]["resolver"]["instances"][instance_id]
    assert instance["adapter"] == "litellm", "model_instance_required"
    headers = {"Authorization": "Bearer " + owner_identity}
    manifest = client.call(
        "request",
        method="POST",
        url=fixture["endpoints"]["resolver"] + "/v1/manifests",
        headers=headers,
        body={"domain": instance["domain"], "include_models": True},
    )
    assert manifest["status"] == 200, "real_model_manifest_required"
    selected = [
        entry
        for entry in json.loads(manifest["body"])["manifest"]["instances"]
        if entry["display_name"] == instance["display_name"]
    ]
    assert len(selected) == 1, "unique_model_reference_required"
    entry = selected[0]
    assert entry["credential_state"] == "prepared", "real_r06_preparation_required"
    response = client.call(
        "request",
        method="POST",
        url=fixture["endpoints"]["resolver"] + "/v1/credentials/redeem",
        headers=headers,
        body={
            "domain": instance["domain"],
            "instance_ref": entry["instance_ref"],
            "auth_ref": entry["auth_ref"],
        },
    )
    assert response["status"] == 200, "real_r06_delivery_required"
    delivered = json.loads(response["body"])
    credential = delivered["credential"]
    assert credential["profile"] == "litellm-key", "native_model_profile_required"
    assert delivered["target"] == instance["target"], "model_delivery_target_mismatch"
    assert isinstance(credential["token"], str) and credential["token"]
    assert type(credential["expires_at"]) is int
    return ModelDelivery(
        credential["token"], delivered["target"], credential["expires_at"]
    )


def known_deny_pair(
    fixture: dict[str, Any],
    client: Client,
    owner_identity: str,
    instance_id: str,
    model: str,
    administrator: str,
    observe: Counts,
    native_observe: NativeObservation,
) -> dict[str, Any]:
    require_native_assignment(fixture)
    endpoint = fixture["endpoints"]["models"]
    original = model_delivery(fixture, client, owner_identity, instance_id)
    digest = hashlib.sha256(original.token.encode()).hexdigest()
    identifier = "sha256:" + digest

    def native_state() -> Mapping[str, Any]:
        state = native_observe(digest)
        assert (
            state["kind"] == "native-key-info"
            and state["issuer"] == endpoint
            and state["native_key_id"] == digest
            and state["observer_uid"] == fixture["models"]["roles"]["resolver"]["uid"]
            and type(state["present"]) is bool
        ), "matching_private_native_observation_required"
        return state

    initial = native_state()
    assert initial["present"], "native_key_presence_required_before_deny"
    native_expiry = initial["expires_at"]
    assert native_expiry > time.time() + 65, "retirement_probe_must_not_be_expiry"
    assert original.expires_at > time.time() + 65, "fresh_delivery_required"
    assert (
        inference(client, endpoint, original.token, model, target=original.target)[
            "status"
        ]
        == 200
    )

    def publish(method: str) -> None:
        response = client.call(
            "request",
            method=method,
            url=fixture["endpoints"]["resolver"] + "/v1/denies",
            headers={"Authorization": "Bearer " + administrator},
            body={"kind": "credential", "issuer": endpoint, "identifier": identifier},
        )
        assert response["status"] == 200, "real_model_deny_administration_required"

    def wait_for_retirement() -> float:
        started = time.monotonic()
        while time.monotonic() - started < 60:
            if not native_state()["present"]:
                return round(time.monotonic() - started, 3)
            time.sleep(1)
        raise AssertionError("healthy_native_retirement_not_observed")

    def retired_key_refusal() -> None:
        assert not native_state()["present"], "retired_native_key_reappeared"
        assert time.time() < min(native_expiry, original.expires_at), (
            "expired_key_is_not_retirement_evidence"
        )
        before = observe()
        response = inference(
            client, endpoint, original.token, model, target=original.target
        )
        assert response["status"] == 401, "native_auth_refusal_not_observed"
        assert observe() == before, "retired_native_key_reached_provider"

    publish("POST")
    try:
        retirement = wait_for_retirement()
        retired_key_refusal()
    finally:
        publish("DELETE")
    fresh = model_delivery(fixture, client, owner_identity, instance_id)
    assert fresh.token != original.token, "fresh_recovery_credential_required"
    assert fresh.target == original.target, "recovery_target_changed"
    assert (
        inference(client, endpoint, fresh.token, model, target=fresh.target)["status"]
        == 200
    ), "fresh_r03_r06_recovery_permit_required"
    retired_key_refusal()
    return {
        "case": "real-model-key-r07-native-retirement-and-fresh-recovery",
        "status": "passed",
        "permits": [200, 200],
        "denials": [401, 401],
        "denial_effects_unchanged": True,
        "denial_layer": "native-authentication-after-observed-native-retirement",
        "live_n05_hook_coverage": False,
        "recovery": "fresh-r03-r06-delivery",
        "original_key_still_denied": True,
        "healthy_native_retirement_seconds": retirement,
    }
