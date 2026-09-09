import copy
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from atrium_litellm import controller as controller_module
from atrium_litellm import native as native_module
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


class ReconciliationNative(Native):
    """Mutable native fixture; all controller planning and verification stay real."""

    def __init__(self):
        super().__init__(
            "http://models.atrium.invalid", "sk-" + secrets.token_urlsafe(32)
        )
        self.credential_rows = {}
        self.model_rows = {}
        self.team_rows = {}
        self.key_rows = {}
        self.credential_reads = []
        self.observe_credentials = lambda rows: rows

    def call(self, method, path, body=None, *, query=None, timeout=None):
        self.operations.append({"method": method, "path": path, "status": 200})
        if method == "GET":
            if path == "/health/readiness":
                return {"status": "healthy"}
            if path == "/openapi.json":
                return {"info": {"version": "1.99.1"}}
            if path == "/router/settings":
                return {"current_values": SAFE_ROUTER}
            if path == "/model/info":
                return {"data": list(self.model_rows.values())}
            if path == "/credentials":
                self.credential_reads.append(timeout)
                rows = self.observe_credentials(copy.deepcopy(self.credential_rows))
                return {"success": True, "credentials": list(rows.values())}
            if path == "/team/info":
                return {
                    "team_id": query["team_id"],
                    "team_info": self.team_rows[query["team_id"]],
                }
            if path == "/key/info":
                return {"key": query["key"], "info": self.key_rows[query["key"]]}
        elif method == "POST":
            if path == "/credentials":
                self.credential_rows[body["credential_name"]] = {
                    "credential_name": body["credential_name"],
                    "credential_info": copy.deepcopy(body["credential_info"]),
                }
                return {"success": True}
            if path == "/model/new":
                self.model_rows[body["model_info"]["id"]] = copy.deepcopy(body)
                return {}
            if path == "/team/new":
                self.team_rows[body["team_id"]] = copy.deepcopy(body)
                return {}
            if path == "/key/block":
                self.key_rows[body["key"]]["blocked"] = True
                return {}
        raise AssertionError(f"Unexpected fixture operation: {method} {path}")


@pytest.fixture
def reconciling_controller(generated, ledger, tmp_path, monkeypatch):
    clock = SimpleNamespace(now=0.0, sleeps=[])

    def sleep(seconds):
        clock.sleeps.append(seconds)
        clock.now += seconds

    timing = SimpleNamespace(monotonic=lambda: clock.now, sleep=sleep, time=lambda: NOW)
    monkeypatch.setattr(native_module, "time", timing)
    monkeypatch.setattr(controller_module, "time", timing)
    document = copy.deepcopy(generated)
    for table in ("teams", "aliases", "model_templates"):
        document[table] = {
            key: row
            for key, row in document[table].items()
            if row["domain"] == "personal:ryan"
        }
    desired = Desired.parse(document)
    path = tmp_path / "snapshot.json"
    atomic_json(path, snapshot())
    native = ReconciliationNative()
    controller = Controller(
        desired,
        ledger,
        native,
        ProtectedSnapshotSource(path, INSTALLATION, ISSUER, path.stat().st_uid),
        transports(desired),
        credential_reader=lambda *_: secrets.token_urlsafe(32),
    )
    return controller, native, clock


def test_full_reconciliation_retries_new_credential_post_create_snapshot(
    reconciling_controller,
):
    controller, native, clock = reconciling_controller

    def observe(rows):
        return {} if len(native.credential_reads) == 3 else rows

    native.observe_credentials = observe
    report = controller.run(rotate=False, now=NOW)
    assert native.credential_reads == [None, 65.0, 65.0, 64.5]
    assert clock.sleeps == [0.5]
    assert [
        op
        for op in native.operations
        if op["method"] == "POST" and op["path"] == "/credentials"
    ] == [{"method": "POST", "path": "/credentials", "status": 200}]
    assert report["adoptions"] == 0
    assert controller.bindings_snapshot.is_file()
    assert controller.service_association_snapshot.is_file()


@pytest.mark.parametrize("observation", ["missing", "mismatch", "late-exact"])
def test_post_create_failure_keeps_original_budget_and_stops_key_mutation(
    reconciling_controller,
    observation,
):
    controller, native, clock = reconciling_controller
    with controller.ledger.locked():
        controller.ledger.remember(parse(snapshot([record()])))
    atomic_json(controller.associations.path, snapshot([], generation=2))
    native.key_rows[KEY] = {"blocked": False}

    def observe(rows):
        count = len(native.credential_reads)
        if count == 2:
            clock.now = 64.0
        elif count > 2:
            if observation == "missing":
                return {}
            if observation == "mismatch":
                for row in rows.values():
                    row["credential_info"] = {"cc.account": "different"}
            else:
                clock.now = 65.0
        return rows

    native.observe_credentials = observe
    with pytest.raises(ControllerError, match="native_credential_not_applied"):
        controller.run(rotate=False, now=NOW)
    assert clock.now == 65.0
    assert native.credential_reads[:3] == [None, 65.0, 1.0]
    assert native.key_rows[KEY]["blocked"] is False
    assert not controller.bindings_snapshot.exists()
    assert not controller.service_association_snapshot.exists()
    assert all(op["path"] != "/key/block" for op in native.operations)
    assert (
        sum(
            op["method"] == "POST" and op["path"] == "/credentials"
            for op in native.operations
        )
        == 1
    )


def test_all_new_credentials_need_one_exact_snapshot_and_share_first_deadline(
    reconciling_controller,
    generated,
):
    controller, native, clock = reconciling_controller
    controller.desired = Desired.parse(copy.deepcopy(generated))

    def observe(rows):
        count = len(native.credential_reads)
        if count == 2:
            clock.now = 60.0
        if count in (3, 4, 5):
            identity = list(rows)[0 if count == 4 else -1]
            return {identity: rows[identity]}
        return rows

    native.observe_credentials = observe
    controller.run(rotate=False, now=NOW)
    assert len(native.credential_rows) == 2
    assert native.credential_reads == [None, 65.0, 5.0, 5.0, 4.5, 4.0]
    assert clock.sleeps == [0.5, 0.5]
    assert clock.now == 61.0
    assert (
        sum(
            op["method"] == "POST" and op["path"] == "/credentials"
            for op in native.operations
        )
        == 2
    )


@pytest.mark.parametrize("stage", ["initial", "post-create"])
@pytest.mark.parametrize(
    ("observation", "error"),
    [
        ("missing", "owned_credential_missing"),
        ("mismatch", "native_account_binding_drift"),
    ],
)
def test_preexisting_owned_credential_failures_never_become_creation_lag(
    reconciling_controller,
    generated,
    stage,
    observation,
    error,
):
    controller, native, clock = reconciling_controller
    controller.run(rotate=False, now=NOW)
    before = controller.bindings_snapshot.read_bytes()
    owned = next(iter(native.credential_rows))
    native.credential_reads.clear()
    if stage == "post-create":
        controller.desired = Desired.parse(copy.deepcopy(generated))

    def observe(rows):
        if stage == "initial" or len(native.credential_reads) == 3:
            if observation == "missing":
                rows.pop(owned)
            else:
                rows[owned]["credential_info"] = {"cc.account": "different"}
            # Existing ownership must be checked even while a new row is missing.
            rows = {key: row for key, row in rows.items() if key == owned}
        return rows

    native.observe_credentials = observe
    with pytest.raises(ControllerError, match=error):
        controller.run(rotate=False, now=NOW)
    assert clock.sleeps == []
    assert len(native.credential_reads) == (1 if stage == "initial" else 3)
    assert controller.bindings_snapshot.read_bytes() == before
