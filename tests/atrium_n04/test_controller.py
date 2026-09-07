import copy
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from atrium_litellm.associations import ProtectedSnapshotSource, Snapshot
from atrium_litellm.controller import Controller
from atrium_litellm.desired import Desired
from atrium_litellm.errors import ControllerError
from atrium_litellm.files import atomic_json, decode, read_bytes
from atrium_litellm.ledger import Ledger
from atrium_litellm.native import Native, SAFE_ROUTER, permissions, verify_key

NOW = 1_800_000_000
INSTALLATION = "fixture-controller-test"
ISSUER = "https://litellm.atrium.invalid"
KEY = "a" * 64


def record():
    return {
        "issuer": ISSUER,
        "credential_id": KEY,
        "native_key_id": KEY,
        "principal_id": "ryan",
        "authority_id": "pocket-id-fixture",
        "domain": "personal:ryan",
        "template_id": "personal-client",
        "native_team_id": "fixture-native-team",
        "issued_at": NOW - 10,
        "expires_at": NOW + 300,
        "device_id": None,
        "state": "active",
        "effective_limits": {
            "models": ["cc.personal.ryan.text"],
            "routes": ["/v1/chat/completions"],
            "budget": {"usd": 1, "duration_seconds": 3600},
        },
    }


def snapshot(records=(), generation=1):
    return {
        "schema_version": 1,
        "kind": "atrium.litellm-associations",
        "installation": INSTALLATION,
        "issuer": ISSUER,
        "generation": generation,
        "generated_at": NOW,
        "expires_at": NOW + 120,
        "associations": list(records),
    }


def parse(value):
    return Snapshot.parse(value, installation=INSTALLATION, issuer=ISSUER, now=NOW)


@pytest.fixture
def ledger(tmp_path):
    path = tmp_path / "inventory"
    path.mkdir(mode=0o700)
    ledger = Ledger(path, INSTALLATION, ISSUER)
    ledger.initialize()
    return ledger


@pytest.mark.parametrize(
    "field,value",
    [
        ("schema_version", 2),
        ("kind", "atrium.deny"),
        ("installation", "foreign"),
        ("issuer", "https://foreign.atrium.invalid"),
        ("generation", 0),
        ("generation", True),
        ("generated_at", NOW + 6),
        ("expires_at", NOW),
        ("expires_at", NOW + 301),
        ("associations", None),
    ],
)
def test_snapshot_rejects_untrusted_envelopes(field, value):
    data = snapshot()
    data[field] = value
    with pytest.raises(ControllerError):
        parse(data)


@pytest.mark.parametrize(
    "field,value",
    [
        ("native_key_id", "b" * 64),
        ("credential_id", "not-a-hash"),
        ("principal_id", "person@example.invalid"),
        ("authority_id", ""),
        ("template_id", None),
        ("native_team_id", None),
        ("state", "legacy"),
        ("expires_at", NOW - 100),
        ("device_id", "arbitrary.device"),
        ("issuer", "foreign"),
    ],
)
def test_snapshot_rejects_invalid_associations(field, value):
    data = record()
    data[field] = value
    with pytest.raises(ControllerError):
        parse(snapshot([data]))


def test_snapshot_no_duplicates_or_arbitrary_routes():
    with pytest.raises(ControllerError, match="duplicate_native_key"):
        parse(snapshot([record(), record()]))
    data = record()
    data["effective_limits"]["routes"] = ["llm_api_routes"]
    with pytest.raises(ControllerError):
        parse(snapshot([data]))


@pytest.mark.parametrize(
    "content", [b'{"one":1,"one":2}', b'{"one":NaN}', b'{"one":Infinity}', b"[]"]
)
def test_json_rejects_ambiguous_or_nonfinite_input(content):
    with pytest.raises(ControllerError):
        decode(content)


def test_missing_corrupt_ledger_is_not_empty(ledger):
    state = ledger.path / "ownership.json"
    state.unlink()
    with pytest.raises(ControllerError):
        ledger.load()
    state.write_text("{}")
    state.chmod(0o600)
    with pytest.raises(ControllerError):
        ledger.load()
    with pytest.raises(ControllerError):
        ledger.initialize()


def test_snapshot_monotonic_history_and_identity(ledger):
    with ledger.locked():
        ledger.remember(parse(snapshot([record()], 2)))
        ledger.remember(parse(snapshot([], 3)))
        assert KEY in ledger.state["keys"]
        for bad in (snapshot([record()], 2), snapshot([record()], 3)):
            with pytest.raises(ControllerError):
                ledger.check_snapshot(parse(bad))
        changed = record()
        changed["principal_id"] = "fixture-child"
        with pytest.raises(ControllerError, match="association_identity_changed"):
            ledger.check_snapshot(parse(snapshot([changed], 4)))
    recovered = Ledger(ledger.path, INSTALLATION, ISSUER).load()
    assert recovered["keys"][KEY]["association"] == record()


def test_ledger_is_installation_qualified(ledger):
    with pytest.raises(ControllerError):
        Ledger(ledger.path, "another-installation", ISSUER).load()


def test_read_only_lock_never_writes(ledger):
    before = {p.name: p.read_bytes() for p in ledger.path.iterdir()}
    with ledger.locked(dry_run=True):
        ledger.check_snapshot(parse(snapshot()))
        with pytest.raises(ControllerError, match="ledger_write_forbidden"):
            ledger.save()
        with pytest.raises(ControllerError, match="ledger_write_forbidden"):
            ledger.remember(parse(snapshot()))
    assert before == {p.name: p.read_bytes() for p in ledger.path.iterdir()}


def test_snapshot_file_trust_and_atomic_read(tmp_path):
    path = tmp_path / "snapshot.json"
    atomic_json(path, snapshot())
    source = ProtectedSnapshotSource(path, INSTALLATION, ISSUER, path.stat().st_uid)
    assert source.read(NOW).records == {}
    path.chmod(0o666)
    with pytest.raises(ControllerError):
        source.read(NOW)
    path.unlink()
    path.symlink_to(tmp_path / "other.json")
    with pytest.raises(ControllerError):
        source.read(NOW)


def test_secret_paths_reject_repository_and_store(tmp_path):
    (tmp_path / ".git").write_text("synthetic repository marker")
    value = tmp_path / "no-credential.txt"
    value.write_text("not a credential")
    value.chmod(0o600)
    with pytest.raises(ControllerError, match="repository_secret_refused"):
        read_bytes(value, secret=True)
    with pytest.raises(ControllerError, match="store_state_refused"):
        read_bytes(Path("/nix/store/does-not-exist"), secret=True)


@pytest.mark.parametrize(
    "mutation",
    [
        "foreign-domain",
        "foreign-account",
        "wildcard",
        "fallback",
        "management",
        "service-lifetime",
        "legacy",
    ],
)
def test_desired_fails_closed(generated, mutation):
    value = copy.deepcopy(generated)
    if mutation == "foreign-domain":
        value["model_backends"]["personal-text"]["domain"] = "family:holt"
    elif mutation == "foreign-account":
        value["model_backends"]["personal-text"]["account"] = "foreign"
    elif mutation == "wildcard":
        value["model_backends"]["personal-text"]["model"] = "openai/*"
    elif mutation == "fallback":
        value["aliases"]["cc.personal.ryan.text"]["fallbacks"] = [
            "cc.family.holt.child"
        ]
    elif mutation == "management":
        value["model_templates"]["personal-client"]["routes"] = ["/key/generate"]
    elif mutation == "service-lifetime":
        value["model_templates"]["whiskey-service"]["max_lifetime_seconds"] = 3
    else:
        value["schema_version"] = 1
    with pytest.raises(ControllerError):
        Desired.parse(value)


class ReadOnlyNative:
    management_id = "f" * 64

    def __init__(self):
        self.calls = []

    def inspect_gateway(self):
        self.calls.append("read-gateway")

    def models(self):
        self.calls.append("read-models")
        return []

    def credentials(self):
        self.calls.append("read-credentials")
        return {}


def transports(desired):
    return {
        key: {"api_base": "http://models.atrium.invalid/v1"}
        for key in desired.document["model_backends"]
    }


def test_dry_run_uses_no_native_mutation_or_ledger_adoption(
    generated, ledger, tmp_path
):
    desired = Desired.parse(copy.deepcopy(generated))
    path = tmp_path / "snapshot.json"
    atomic_json(path, snapshot())
    native = ReadOnlyNative()
    controller = Controller(
        desired,
        ledger,
        native,
        ProtectedSnapshotSource(path, INSTALLATION, ISSUER, path.stat().st_uid),
        transports(desired),
    )
    before = (ledger.path / "ownership.json").read_bytes()
    report = controller.run(dry_run=True, now=NOW)
    assert report["adoptions"] == 0
    assert all(call.startswith("read-") for call in native.calls)
    assert any(a["action"] == "create-team" for a in report["actions"])
    assert before == (ledger.path / "ownership.json").read_bytes()
    assert ledger.load()["teams"] == {}


def test_native_management_client_cannot_call_inference():
    native = Native("http://127.0.0.1:1", "sk-" + "not-a-live-credential")
    with pytest.raises(ControllerError, match="controller_route_forbidden"):
        native.call("POST", "/v1/chat/completions", {})
    assert native.operations == []


def test_native_readback_checks_every_ceiling_and_does_not_reset_spend(generated):
    desired = Desired.parse(copy.deepcopy(generated))
    assoc = record()
    teams = {
        "cc.personal.ryan": {"native_id": assoc["native_team_id"], "status": "owned"}
    }
    ceiling = desired.key_ceiling(assoc, teams, source="resolver", now=NOW)
    info = {
        **permissions(assoc, ceiling),
        "expires": datetime.fromtimestamp(
            assoc["expires_at"], timezone.utc
        ).isoformat(),
        "blocked": False,
    }
    verify_key(info, assoc, ceiling, now=NOW)
    assert "spend" not in permissions(assoc, ceiling)
    for field, bad in (
        ("allowed_routes", []),
        ("models", []),
        ("team_id", "foreign"),
        ("max_budget", 9),
        ("budget_duration", "1m"),
        ("blocked", True),
        ("metadata", {}),
        ("aliases", {"cc.personal.ryan.text": "family-fixture"}),
        ("access_group_ids", ["foreign-model-grants"]),
        ("object_permission", {"models": ["family-fixture"]}),
        ("router_settings", {**SAFE_ROUTER, "fallbacks": ["family-fixture"]}),
    ):
        with pytest.raises(ControllerError):
            verify_key({**info, field: bad}, assoc, ceiling, now=NOW)


def test_missing_metadata_still_reconciles_known_key(generated, ledger):
    desired = Desired.parse(copy.deepcopy(generated))
    assoc = record()
    with ledger.locked():
        ledger.state["teams"]["cc.personal.ryan"] = {
            "native_id": assoc["native_team_id"],
            "status": "owned",
            "domain": "personal:ryan",
            "provenance": "controller-created",
        }
        ledger.remember(parse(snapshot([assoc])))
        ceiling = desired.key_ceiling(
            assoc, ledger.state["teams"], source="resolver", now=NOW
        )
        info = {
            **permissions(assoc, ceiling),
            "metadata": {},
            "expires": datetime.fromtimestamp(
                assoc["expires_at"], timezone.utc
            ).isoformat(),
        }

        class KnownNative(ReadOnlyNative):
            def key(self, key):
                assert key == KEY
                return info

        controller = Controller(
            desired, ledger, KnownNative(), None, transports(desired)
        )
        assert (
            controller._key_plan(ledger.state, parse(snapshot([assoc])), NOW)[0][
                "action"
            ]
            == "update-key"
        )
        assert (
            controller._key_plan(ledger.state, parse(snapshot()), NOW)[0]["action"]
            == "block-key"
        )
        del desired.document["model_templates"]["personal-client"]
        assert (
            controller._key_plan(ledger.state, parse(snapshot([assoc])), NOW)[0][
                "action"
            ]
            == "block-key"
        )


def test_ledger_digest_detects_semantic_corruption(ledger):
    path = ledger.path / "ownership.json"
    envelope = json.loads(path.read_text())
    envelope["state"]["teams"]["cc.not-provenance"] = {}
    atomic_json(path, envelope)
    with pytest.raises(ControllerError, match="corrupt_ledger"):
        ledger.load()


def test_fractional_native_expiry_cannot_exceed_ceiling(generated):
    desired = Desired.parse(copy.deepcopy(generated))
    assoc = record()
    teams = {
        "cc.personal.ryan": {"native_id": assoc["native_team_id"], "status": "owned"}
    }
    ceiling = desired.key_ceiling(assoc, teams, source="resolver", now=NOW)
    info = {
        **permissions(assoc, ceiling),
        "expires": datetime.fromtimestamp(
            ceiling["expires_at"] + 0.1, timezone.utc
        ).isoformat(),
    }
    with pytest.raises(ControllerError, match="native_key_expiry_mismatch"):
        verify_key(info, assoc, ceiling, now=NOW)
