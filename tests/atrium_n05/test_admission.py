import copy
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from atrium_profiles import ProfileError
from atrium_profiles.deny import DenyClaims
from atrium_profiles.keyring import SigningKeyRing
from atrium_profiles.runtime import atomic_private_write
from atrium_resolver import __file__ as resolver_file
from atrium_resolver.policy_schema import PolicyDocument

from atrium_admission.engine import Admission
from atrium_admission.models import AdmissionError, Settings
from atrium_admission.state import State


@pytest.fixture
def fixture(tmp_path):
    now = int(time.time())
    keyring = SigningKeyRing(tmp_path / "signing", "https://resolver.atrium.invalid")
    keyring.initialize(now=now - 2000)
    raw = {"generation": 1, "issued_at": now, "deny": ()}

    def token():
        return keyring.sign_deny(
            DenyClaims(
                iss=keyring.issuer,
                generation=raw["generation"],
                issued_at=raw["issued_at"],
                fresh_until=raw["issued_at"] + 30,
                principals=raw["deny"],
                credentials=(),
                devices=(),
            ),
            now=raw["issued_at"],
        )

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            value = (
                json.dumps(keyring.jwks(now=now)).encode()
                if self.path == "/jwks"
                else raw.get("token", token()).encode()
            )
            self.send_response(raw.get("status", 200))
            self.send_header("Content-Length", str(len(value)))
            self.end_headers()
            self.wfile.write(value)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    policy = json.loads(
        (Path(resolver_file).parents[2] / "fixtures/policy.generated.json").read_text()
    )
    runtime = tmp_path / "admission"
    inputs = tmp_path / "inputs"
    inputs.mkdir(mode=0o700)
    policy_path = inputs / "policy.json"
    atomic_private_write(policy_path, json.dumps(policy).encode())
    primary, service = inputs / "resolver.json", inputs / "service.json"
    issuer = "https://models.atrium.invalid"
    settings = Settings.model_validate(
        {
            "schema_version": 1,
            "isolated": True,
            "installation": "fixture",
            "issuer": issuer,
            "runtime_directory": runtime,
            "policy_path": policy_path,
            "policy_publisher_uid": os.geteuid(),
            "producers": (
                {
                    "id": "resolver",
                    "kind": "resolver",
                    "path": primary,
                    "publisher_uid": os.geteuid(),
                },
                {
                    "id": "services",
                    "kind": "controller-service",
                    "path": service,
                    "publisher_uid": os.geteuid(),
                },
            ),
            "deny_issuer": keyring.issuer,
            "deny_url": f"http://127.0.0.1:{server.server_port}/deny",
            "jwks_url": f"http://127.0.0.1:{server.server_port}/jwks",
            "poll_seconds": 20,
        }
    )
    key = secrets.token_hex(32)
    record = {
        "issuer": issuer,
        "credential_id": "sha256:" + key,
        "native_key_id": key,
        "principal": "fixture-child",
        "authority": "fixture-pocket-id",
        "domain": "family:fixture",
        "instance": "family-models",
        "target": policy["instances"]["family-models"]["target"],
        "audience": "models",
        "template_id": "child-client",
        "team_id": "native-family",
        "issued_at": now - 20,
        "expires_at": now + 800,
        "device_id": None,
        "admin_outage_eligible": False,
        "models": ["cc.family.text"],
        "routes": ["/v1/chat/completions"],
        "budget": {"usd": 1.0, "duration_seconds": 3600},
        "operation_id": "a" * 64,
        "status": "prepared",
    }
    documents = {
        "resolver": {
            "schema_version": 1,
            "kind": "atrium.litellm-admission-associations",
            "installation": "fixture",
            "issuer": issuer,
            "generation": 1,
            "issued_at": now,
            "credentials": [record],
        },
        "services": {
            "schema_version": 1,
            "kind": "atrium.litellm-associations",
            "installation": "fixture",
            "issuer": issuer,
            "generation": 1,
            "generated_at": now,
            "expires_at": now + 300,
            "associations": [],
        },
    }

    def publish():
        atomic_private_write(primary, json.dumps(documents["resolver"]).encode())
        atomic_private_write(service, json.dumps(documents["services"]).encode())

    publish()
    State(settings).initialize()
    engine = Admission(settings, start_poller=False)
    data = {
        "now": now,
        "settings": settings,
        "engine": engine,
        "key": key,
        "record": record,
        "documents": documents,
        "publish": publish,
        "raw": raw,
        "primary": primary,
        "service": service,
        "policy": policy,
        "policy_path": policy_path,
    }
    try:
        yield data
    finally:
        engine.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def admit(fixture, **changes):
    return fixture["engine"].admit(
        **{
            "key_hash": fixture["key"],
            "native_team": "native-family",
            "model": "cc.family.text",
            "path": "/v1/chat/completions",
            **changes,
        }
    )


def test_actual_profile_cache_applies_a_signed_deny_and_preserves_non_owned(fixture):
    f = fixture
    assert admit(f) == "fresh"
    f["raw"].update(generation=2, deny=("fixture-child",))
    f["engine"].feed.poll(force=True)
    with pytest.raises(ProfileError, match="principal_denied"):
        admit(f)
    assert admit(f, key_hash="f" * 64) == "verified-non-owned"


@pytest.mark.parametrize(
    "context",
    [{"model": None}, {"path": None}, {"model": {"caller": "label"}, "path": []}],
)
def test_context_requirements_apply_only_after_verified_ownership(fixture, context):
    assert admit(fixture, key_hash="f" * 64, **context) == "verified-non-owned"
    with pytest.raises(AdmissionError, match="owned_request_context_unsupported"):
        admit(fixture, **context)
    fixture["primary"].unlink()
    with pytest.raises(AdmissionError, match="ownership_unverified"):
        admit(fixture, key_hash="f" * 64, **context)


@pytest.mark.parametrize("status", ["reserved", "cleanup", "revoked"])
def test_non_admitting_lifecycle_states_never_fall_back_to_legacy(fixture, status):
    f = fixture
    assert admit(f) == "fresh"
    f["record"]["status"] = status
    f["documents"]["resolver"]["generation"] += 1
    f["publish"]()
    with pytest.raises(AdmissionError):
        admit(f)


@pytest.mark.parametrize(
    "fault", ["missing", "corrupt", "rollback", "same-generation", "omitted"]
)
def test_producer_faults_keep_known_owned_identity_across_restart(fixture, fault):
    f = fixture
    assert admit(f) == "fresh"
    original = copy.deepcopy(f["documents"]["resolver"])
    f["documents"]["resolver"]["generation"] = 2
    f["publish"]()
    assert admit(f) == "fresh"
    if fault == "missing":
        f["primary"].unlink()
    elif fault == "corrupt":
        atomic_private_write(f["primary"], b"{}")
    else:
        if fault == "rollback":
            f["documents"]["resolver"] = original
        elif fault == "same-generation":
            f["documents"]["resolver"]["credentials"] = []
        else:
            f["documents"]["resolver"]["credentials"] = []
            f["documents"]["resolver"]["generation"] = 3
        f["publish"]()
    f["engine"].close()
    f["engine"] = Admission(f["settings"], start_poller=False)
    with pytest.raises(AdmissionError):
        admit(f)
    with f["engine"].store.transaction() as state:
        assert f["key"] in state["history"]


@pytest.mark.parametrize(
    "changes",
    [
        {"native_team": "foreign"},
        {"model": "cc.personal.text"},
        {"path": "/key/delete"},
    ],
)
def test_native_binding_model_and_route_ceilings_remain_mandatory(fixture, changes):
    assert admit(fixture) == "fresh"
    with pytest.raises(AdmissionError, match="owned_request_not_permitted"):
        admit(fixture, **changes)


@pytest.mark.parametrize("ceiling", ["instance", "template", "group"])
def test_current_acl_removal_refuses_an_unexpired_historical_grant(fixture, ceiling):
    f = fixture
    assert admit(f) == "fresh"
    original = copy.deepcopy(f["policy"])
    if ceiling == "instance":
        f["policy"]["instances"]["family-models"]["acl"] = {
            "principals": ["fixture-peer"],
            "groups": ["fixture-parents"],
        }
    if ceiling in ("instance", "template"):
        f["policy"]["model_templates"]["child-client"]["acl"] = {
            "principals": ["fixture-peer"],
            "groups": [],
        }
        f["policy"]["principal_model_allowlists"]["fixture-child"] = {}
    elif ceiling == "group":
        f["policy"]["principals"]["fixture-child"]["groups"] = []
        f["policy"]["principal_model_allowlists"]["fixture-child"] = {}
    PolicyDocument.model_validate_json(json.dumps(f["policy"]))
    atomic_private_write(f["policy_path"], json.dumps(f["policy"]).encode())
    with pytest.raises(AdmissionError, match="owned_request_not_permitted"):
        admit(f)
    atomic_private_write(f["policy_path"], json.dumps(original).encode())
    assert admit(f) == "fresh"


@pytest.mark.parametrize("failure", ["timeout", "malformed"])
def test_failed_poll_records_completion_time_before_clock_rollback(
    fixture, monkeypatch, failure
):
    f = fixture
    assert admit(f) == "fresh"
    clock = [f["now"]]
    monkeypatch.setattr("atrium_admission.state.time.time", lambda: clock[0])
    original = f["engine"].feed._fetch

    async def failed_fetch():
        keys, document = await original()
        clock[0] = f["now"] + 361
        if failure == "timeout":
            raise TimeoutError()
        return b"malformed", document

    monkeypatch.setattr(f["engine"].feed, "_fetch", failed_fetch)
    f["engine"].feed.poll(force=True)
    with f["engine"].store.transaction() as state:
        assert state["last_now"] == f["now"] + 361
    clock[0] = f["now"] + 10
    f["documents"]["services"].update(
        generation=2, generated_at=f["now"] + 361, expires_at=f["now"] + 661
    )
    f["publish"]()
    with pytest.raises(ProfileError, match="deny_feed_stale"):
        admit(f)


def test_clock_observation_survives_publication_failure(fixture, monkeypatch):
    from atrium_admission import state as state_module

    f = fixture
    assert admit(f) == "fresh"
    original = state_module.atomic_private_write

    def unavailable(*_args):
        raise OSError("fixture storage failure")

    monkeypatch.setattr(state_module, "atomic_private_write", unavailable)
    with pytest.raises(OSError):
        f["engine"].store.observe_clock(minimum=f["now"] + 361)
    monkeypatch.setattr(state_module, "atomic_private_write", original)
    f["engine"].store.observe_clock(minimum=f["now"] + 10)
    with f["engine"].store.transaction() as state:
        assert state["last_now"] >= f["now"] + 361


def test_duplicate_clock_observations_do_not_republish_state(fixture, monkeypatch):
    from atrium_admission import state as state_module

    f = fixture
    monkeypatch.setattr(state_module.time, "time", lambda: f["now"])
    f["engine"].store.observe_clock()

    def unexpected_write(*_args):
        pytest.fail("Unchanged clock state was republished")

    monkeypatch.setattr(state_module, "atomic_private_write", unexpected_write)
    f["engine"].store.observe_clock()


def test_feed_invalid_and_rollback_preserve_last_verified_denies(fixture):
    f = fixture
    assert admit(f) == "fresh"
    f["raw"].update(generation=2, deny=("fixture-child",))
    f["engine"].feed.poll(force=True)
    for changes in ({"token": "invalid"}, {"generation": 1, "deny": ()}):
        f["raw"].pop("token", None)
        f["raw"].update(changes)
        f["engine"].feed.poll(force=True)
        with pytest.raises(ProfileError, match="principal_denied"):
            admit(f)


@pytest.mark.parametrize(
    "age,expected",
    [(29, "fresh"), (30, "bounded-stale"), (300, "bounded-stale"), (301, "deny")],
)
def test_shared_c1_boundaries_are_not_reimplemented(
    fixture, monkeypatch, age, expected
):
    f = fixture
    monkeypatch.setattr("atrium_admission.state.time.time", lambda: f["now"])
    f["raw"]["issued_at"] = f["now"] - age
    f["engine"].feed.poll(force=True)
    if expected == "deny":
        with pytest.raises(ProfileError, match="deny_feed_stale"):
            admit(f)
    else:
        assert admit(f) == expected


def administrator(f):
    instance = f["policy"]["instances"]["personal-models"]
    f["record"].update(
        principal="fixture-admin",
        domain="personal:fixture",
        instance="personal-models",
        target=instance["target"],
        template_id="personal-client",
        team_id="native-personal",
        models=["cc.personal.text"],
        admin_outage_eligible=True,
    )
    f["publish"]()


def admin_admit(f):
    return admit(f, native_team="native-personal", model="cc.personal.text")


@pytest.mark.parametrize("missing", [True, False])
def test_verified_human_admin_exception_uses_actual_durable_alert(fixture, missing):
    f = fixture
    administrator(f)
    if missing:
        f["raw"]["status"] = 503
    else:
        f["raw"]["issued_at"] = int(time.time()) - 301
    f["engine"].feed.poll(force=True)
    assert admin_admit(f) == "admin-freshness"
    event = json.loads(f["engine"].alerts.path.read_text())
    assert event["principal"] == "fixture-admin" and event["reason"] == (
        "missing" if missing else "stale"
    )
    assert event["credential"]["id"] == "sha256:" + f["key"]


def test_known_denied_admin_never_uses_freshness_exception(fixture):
    f = fixture
    administrator(f)
    f["raw"].update(issued_at=int(time.time()) - 301, deny=("fixture-admin",))
    f["engine"].feed.poll(force=True)
    with pytest.raises(ProfileError, match="principal_denied"):
        admin_admit(f)
    assert not f["engine"].alerts.path.exists()


def test_admin_exception_cannot_bypass_expiry_or_alert_failure(fixture):
    f = fixture
    administrator(f)
    f["raw"]["status"] = 503
    assert admin_admit(f) == "admin-freshness"
    f["engine"].alerts.path.chmod(0o644)
    with pytest.raises(ProfileError, match="insecure_runtime_file"):
        admin_admit(f)
    f["record"]["expires_at"] = f["now"] - 1
    f["documents"]["resolver"]["generation"] += 1
    f["publish"]()
    with pytest.raises(AdmissionError, match="owned_request_not_permitted"):
        admin_admit(f)


def test_service_controller_provenance_never_becomes_admin(fixture):
    f = fixture
    f["documents"]["resolver"]["credentials"] = []
    f["documents"]["services"]["associations"] = [
        {
            "issuer": f["settings"].issuer,
            "credential_id": f["key"],
            "native_key_id": f["key"],
            "principal_id": "fixture-text-service",
            "authority_id": "controller",
            "domain": "personal:fixture",
            "template_id": "whiskey-service",
            "native_team_id": "native-personal",
            "issued_at": f["now"] - 20,
            "expires_at": f["now"] + 800,
            "device_id": None,
            "state": "active",
            "effective_limits": {
                "models": ["cc.personal.text"],
                "routes": ["/v1/chat/completions"],
                "budget": {"usd": 1.0, "duration_seconds": 3600},
            },
        }
    ]
    f["publish"]()
    assert admin_admit(f) == "fresh"
    f["raw"].update(generation=2, issued_at=int(time.time()) - 301)
    f["engine"].feed.poll(force=True)
    with pytest.raises(ProfileError, match="deny_feed_stale"):
        admin_admit(f)
    assert not f["engine"].alerts.path.exists()


def test_omitted_owned_key_never_becomes_non_owned_with_a_fresh_empty_producer(fixture):
    f = fixture
    assert admit(f) == "fresh"
    f["documents"]["resolver"].update(generation=2, credentials=[])
    f["publish"]()
    with pytest.raises(AdmissionError, match="owned_authorization_unavailable"):
        admit(f)
    assert admit(f, key_hash="f" * 64) == "verified-non-owned"


def test_missing_history_cannot_be_bootstrapped_by_normal_admission(fixture):
    f = fixture
    assert admit(f) == "fresh"
    f["engine"].store.path.unlink()
    with pytest.raises(FileNotFoundError):
        admit(f)
    with pytest.raises(AdmissionError, match="admission_already_initialized"):
        f["engine"].store.initialize()
