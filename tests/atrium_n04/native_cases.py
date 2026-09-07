import copy
import hashlib
import json
import os
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

from atrium_litellm.associations import ProtectedSnapshotSource
from atrium_litellm.controller import Controller
from atrium_litellm.desired import Desired
from atrium_litellm.errors import ControllerError, require
from atrium_litellm.files import atomic_json, canonical, digest, read_json
from atrium_litellm.ledger import Ledger
from atrium_litellm.native import (
    CONTROL_ROUTES,
    Native,
    SAFE_ROUTER,
    expiration,
    metadata,
    verify_key,
)
from atrium_litellm.rotation import ServiceKey


class Fixture:
    def __init__(self, data, result):
        self.data, self.result = data, result
        self.consumer = None
        self.records = {}
        self.generation = 0
        self.issuer = "https://litellm." + data["installation"] + ".atrium.invalid"
        self.root = Path.cwd()
        for name in ("inventory", "input", "providers", "delivery", "acks"):
            Path(name).mkdir(mode=0o700)
        Path("delivery").chmod(0o750)
        os.chown("delivery", 0, 65532)
        os.chown("acks", 65532, 0)
        Path("acks").chmod(0o750)
        document = copy.deepcopy(data["desired"])
        document["providers"]["fixture-model"]["egress_hosts"] = [
            data["provider"],
            data["family_provider"],
        ]
        for name in ("personal-model", "family-model"):
            path = Path("providers") / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(
                    data["provider_key"]
                    if name == "personal-model"
                    else data["family_provider_key"]
                )
            document["service_credentials"][name]["runtime_path"] = str(
                self.root / path
            )
        self.desired = Desired.parse(document)
        self.transports = {
            name: {
                "api_base": "http://"
                + (
                    data["provider"]
                    if row["domain"] == "personal:ryan"
                    else data["family_provider"]
                )
                + ":8000/v1"
            }
            for name, row in document["model_backends"].items()
        }
        self.snapshot_path = self.root / "input/associations.json"
        self.source = ProtectedSnapshotSource(
            self.snapshot_path, data["installation"], self.issuer, os.geteuid()
        )
        self.ledger = Ledger(self.root / "inventory", data["installation"], self.issuer)
        self.ledger.initialize()
        self.publish()
        self.client = httpx.Client(
            base_url=data["endpoint"],
            timeout=25,
            trust_env=False,
            follow_redirects=False,
        )
        self.observer = httpx.Client(
            base_url="http://" + data["provider"] + ":8000",
            timeout=10,
            trust_env=False,
            follow_redirects=False,
        )
        self.family_observer = httpx.Client(
            base_url="http://" + data["family_provider"] + ":8000",
            timeout=10,
            trust_env=False,
            follow_redirects=False,
        )
        self.master = data["management_key"]
        self.management_ops = result.setdefault("management_operations", [])
        self.call(
            "POST",
            "/user/new",
            {
                "user_id": "fixture-controller-admin",
                "user_role": "proxy_admin",
                "auto_create_key": False,
            },
        )
        controller_key = self.call(
            "POST",
            "/key/generate",
            {
                "user_id": "fixture-controller-admin",
                "duration": "15m",
                "key_type": "default",
                "allowed_routes": sorted(set().union(*CONTROL_ROUTES.values())),
            },
        )["key"]
        self.native = Native(
            data["endpoint"],
            controller_key,
            operations=result.setdefault("controller_operations", []),
        )
        self.control_key = controller_key
        self.controller = Controller(
            self.desired,
            self.ledger,
            self.native,
            self.source,
            self.transports,
            service_delivery={
                "whiskey-service": {
                    "ack_path": str(self.root / "acks/key.json"),
                    "consumer_uid": 65532,
                    "consumer_gid": 65532,
                    "ack_timeout_seconds": 60,
                }
            },
        )

    def close(self):
        if self.consumer:
            if self.consumer.poll() is None:
                try:
                    self.consumer.stdin.write('{"action":"stop"}\n')
                    self.consumer.stdin.flush()
                    self.consumer.wait(timeout=10)
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    self.consumer.terminate()
                    self.consumer.wait(timeout=5)
            self.result["consumer_cleanup"] = {
                "exited": self.consumer.poll() is not None
            }
            self.consumer.stdin.close()
            self.consumer.stdout.close()
        self.client.close()
        self.observer.close()
        self.family_observer.close()

    def call(self, method, path, body=None, key=None, status=200):
        response = self.client.request(
            method,
            path,
            json=body,
            headers={
                "Authorization": "Bearer " + (self.master if key is None else key)
            },
        )
        self.management_ops.append(
            {
                "method": method,
                "path": path.split("?")[0],
                "status": response.status_code,
            }
        )
        require(response.status_code == status, "fixture_native_setup_failed")
        return response.json()

    def counts(self):
        accounts = {}
        for account, observer in (
            ("ryan-isolated-fixture", self.observer),
            ("holt-isolated-fixture", self.family_observer),
        ):
            response = observer.get(
                "/_fixture/counts",
                headers={
                    "Authorization": "Bearer " + self.data["observer_key"],
                },
            )
            require(response.status_code == 200, "provider_observer_failed")
            accounts[account] = response.json()
        return {
            "received": sum(row["received"] for row in accounts.values()),
            "authorized": sum(row["authorized"] for row in accounts.values()),
            "accounts": accounts,
        }

    def publish(self):
        self.generation += 1
        now = int(time.time())
        atomic_json(
            self.snapshot_path,
            {
                "schema_version": 1,
                "kind": "atrium.litellm-associations",
                "installation": self.data["installation"],
                "issuer": self.issuer,
                "generation": self.generation,
                "generated_at": now,
                "expires_at": now + 300,
                "associations": list(self.records.values()),
            },
        )

    def mint(self, template_id, principal, *, native_user=None):
        now = int(time.time())
        template = self.desired.templates[template_id]
        bindings = read_json(self.controller.bindings_snapshot)
        require(
            bindings["kind"] == "atrium.litellm-bindings"
            and bindings["schema_version"] == 1
            and bindings["installation"] == self.data["installation"]
            and bindings["issuer"] == self.issuer
            and bindings["desired_state_sha256"] == digest(self.desired.document)
            and now < bindings["expires_at"],
            "native_bindings_not_verified",
        )
        team = bindings["teams"][template["team"]]["native_team_id"]
        raw = "sk-" + secrets.token_urlsafe(36)
        identity = hashlib.sha256(raw.encode()).hexdigest()
        record = {
            "issuer": self.issuer,
            "credential_id": identity,
            "native_key_id": identity,
            "principal_id": principal,
            "authority_id": "pocket-id-fixture",
            "domain": template["domain"],
            "template_id": template_id,
            "native_team_id": team,
            "issued_at": now,
            "expires_at": now + 300,
            "device_id": None,
            "state": "active",
            "effective_limits": {
                k: template[k] for k in ("models", "routes", "budget")
            },
        }
        ceiling = self.desired.key_ceiling(
            record, self.ledger.load()["teams"], source="resolver", now=now
        )
        require(ceiling is not None, "fixture_issuance_ceiling_missing")
        generated = self.native.generate(raw, record, ceiling, now=now)
        record["expires_at"] = expiration(generated["expires"])
        ceiling["expires_at"] = record["expires_at"]
        patch = {"key": identity, "metadata": metadata(record, record["expires_at"])}
        if native_user:
            patch["user_id"] = native_user
        self.native.call("POST", "/key/update", patch)
        verify_key(self.native.key(identity), record, ceiling, now=now)
        self.records[identity] = record
        self.publish()
        return raw, identity

    def inference(self, raw, model):
        return self.client.post(
            "/v1/chat/completions",
            headers={"Authorization": "Bearer " + raw},
            json={
                "model": model,
                "messages": [{"role": "user", "content": "Synthetic N04 fixture."}],
                "max_tokens": 4,
                "stream": False,
            },
        )

    def permit(self, raw, model, destination):
        before = self.counts()
        response = self.inference(raw, model)
        self.result.setdefault("inference_observations", []).append(
            {
                "model": model,
                "status": response.status_code,
                "provider_requests": self.counts()["received"] - before["received"],
            }
        )
        require(response.status_code == 200, "native_permit_failed")
        require(
            response.json()["choices"][0]["message"]["content"] == "fixture-ok",
            "provider_output_mismatch",
        )
        after = self.counts()
        backend = self.desired.aliases[model]["backends"][0]
        account = self.desired.document["model_backends"][backend]["account"]
        require(
            after["received"] == before["received"] + 1
            and after["authorized"] == before["authorized"] + 1
            and after["accounts"][account]["models"][-1] == destination
            and after["accounts"][account]["authorized"]
            == before["accounts"][account]["authorized"] + 1,
            "native_destination_mismatch",
        )
        return {
            "status": 200,
            "provider_requests": 1,
            "destination": destination,
            "account": account,
        }

    def deny(self, raw, model):
        before = self.counts()
        response = self.inference(raw, model)
        require(response.status_code in (401, 403), "native_deny_failed")
        require(self.counts() == before, "denied_request_reached_provider")
        return {"status": response.status_code, "provider_requests": 0}

    def case(self, name, gates, **observations):
        self.result["cases"].append(
            {
                "id": "n04." + name,
                "status": "passed",
                "related_gates": gates,
                **observations,
            }
        )

    def expected_failure(self, function, codes):
        before = self.counts()
        try:
            function()
        except ControllerError as exc:
            require(exc.code in codes, "unexpected_controller_failure")
            require(self.counts() == before, "controller_denial_reached_provider")
            return {"code": exc.code, "provider_requests": 0}
        raise ControllerError("controller_did_not_fail_closed")

    def native_snapshot(self):
        rows = {
            "unowned-team": self.call("GET", "/team/info?team_id=" + self.unowned_team)[
                "team_info"
            ],
            "unowned-key": self.call("GET", "/key/info?key=" + self.unowned_hash)[
                "info"
            ],
            "unowned-member-key": self.call(
                "GET", "/key/info?key=" + self.unowned_member_hash
            )["info"],
            "unowned-models": [
                m
                for m in self.native.models()
                if m["model_name"] in ("personal-fixture", "family-fixture")
            ],
        }
        return {name: {"sha256": digest(row)} for name, row in rows.items()}

    def start_consumer(self):
        def identity():
            os.setgroups([65532])
            os.setgid(65532)
            os.setuid(65532)

        self.consumer = subprocess.Popen(
            [sys.executable, "-B", "code/native_consumer.py"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            preexec_fn=identity,
        )
        self.consumer.stdin.write(
            json.dumps(
                {
                    "key_path": str(self.root / "delivery/key.json"),
                    "ack_path": str(self.root / "acks/key.json"),
                    "endpoint": self.data["endpoint"],
                    "model": "cc.personal.ryan.text",
                    "owner_uid": os.geteuid(),
                }
            )
            + "\n"
        )
        self.consumer.stdin.flush()
        first = self.consume()
        require(
            first["requests"][0]["status"] == "read-failed",
            "consumer_missing_file_not_refused",
        )
        self.result["consumer_pid"] = first["pid"]
        return first

    def consume(self, count=1, wait=True):
        self.consumer.stdin.write(
            json.dumps({"action": "request", "count": count}) + "\n"
        )
        self.consumer.stdin.flush()
        if wait:
            return self.consumer_result()

    def consumer_result(self):
        result = json.loads(self.consumer.stdout.readline())
        require(result["pid"] == self.consumer.pid, "consumer_restarted")
        return result


def exercise_basics(f):
    f.result["phase"] = "controller-bootstrap"
    health = f.call("GET", "/health/readiness")
    schema = f.call("GET", "/openapi.json")
    router_response = f.client.get(
        "/router/settings", headers={"Authorization": "Bearer " + f.control_key}
    )
    f.result["native_readback"] = {
        "health_fields": sorted(health),
        "litellm_version": schema.get("info", {}).get("version"),
        "router_status": router_response.status_code,
    }
    if router_response.status_code == 200:
        data = router_response.json()
        f.result["native_readback"]["router_fields"] = (
            sorted(data) if isinstance(data, dict) else ["not-object"]
        )
        if isinstance(data, dict):
            f.result["native_readback"]["safe_router_values"] = {
                k: data.get("current_values", {}).get(k) for k in SAFE_ROUTER
            }
    initial_ledger = (f.ledger.path / "ownership.json").read_bytes()
    first_dry = f.controller.run(dry_run=True, rotate=False)
    require(
        (f.ledger.path / "ownership.json").read_bytes() == initial_ledger,
        "dry_run_changed_ledger",
    )
    require(
        all(op["method"] == "GET" for op in f.native.operations),
        "dry_run_changed_native_state",
    )
    f.controller.run(rotate=False)
    f.case(
        "bootstrap-and-dry-run",
        ["T19"],
        zero_adoptions=first_dry["adoptions"],
        dry_run_ledger_mutations=0,
        dry_run_native_mutations=0,
        native_owned_teams=len(f.ledger.load()["teams"]),
        native_owned_alias_bindings=len(f.ledger.load()["aliases"]),
    )
    f.call(
        "POST",
        "/user/new",
        {
            "user_id": "fixture-human-native-admin",
            "user_role": "proxy_admin",
            "auto_create_key": False,
        },
    )
    admin = f.call("GET", "/user/info?user_id=fixture-human-native-admin")
    role = admin.get("user_info", {}).get("user_role", admin.get("user_role"))
    require(role == "proxy_admin", "fixture_native_admin_role_not_verified")
    f.result["native_human_owner_role"] = role
    personal, personal_hash = f.mint(
        "personal-client", "ryan", native_user="fixture-human-native-admin"
    )
    child, child_hash = f.mint("family-child", "fixture-child")
    retiring, retiring_hash = f.mint("personal-retiring", "ryan")
    adult, _adult_hash = f.mint("family-adult", "ryan")
    f.adult_key = adult
    f.result["phase"] = "unowned-preservation"
    f.unowned_team = "fixture-unowned-" + secrets.token_hex(8)
    f.call(
        "POST",
        "/team/new",
        {
            "team_id": f.unowned_team,
            "team_alias": "cc.personal.ryan",
            "models": ["personal-fixture"],
            "metadata": {"fixture-sentinel": "unchanged"},
        },
    )
    unowned = f.call(
        "POST",
        "/key/generate",
        {
            "team_id": f.unowned_team,
            "key_alias": "cc.personal-client",
            "models": ["personal-fixture"],
            "duration": "10m",
            "allowed_routes": ["/v1/chat/completions"],
            "key_type": "default",
            "metadata": {
                "cc.owner": "command-center",
                "cc.template": "personal-retiring",
                "fixture-sentinel": "unadopted",
            },
        },
    )["key"]
    f.unowned_hash = hashlib.sha256(unowned.encode()).hexdigest()
    member = f.call(
        "POST",
        "/key/generate",
        {
            "team_id": f.ledger.load()["teams"]["cc.personal.ryan"]["native_id"],
            "key_alias": "cc.personal-client-member",
            "models": ["cc.personal.ryan.text"],
            "duration": "10m",
            "allowed_routes": ["/v1/chat/completions"],
            "key_type": "default",
            "metadata": {"fixture-sentinel": "unowned-member"},
        },
    )["key"]
    f.unowned_member_hash = hashlib.sha256(member.encode()).hexdigest()
    unowned_before = f.native_snapshot()
    before_permit = f.permit(personal, "cc.personal.ryan.text", "fixture-personal")
    f.controller.run(rotate=False)
    after_permit = f.permit(personal, "cc.personal.ryan.text", "fixture-personal")
    require(f.native_snapshot() == unowned_before, "controller_changed_unowned_state")
    f.case(
        "runtime-key-survives-deploy",
        ["T19"],
        before=before_permit,
        after=after_permit,
        native_unowned_sha256_before=unowned_before,
        native_unowned_sha256_after=f.native_snapshot(),
    )
    f.case(
        "domain-ceiling",
        ["T5"],
        permit=f.permit(personal, "cc.personal.ryan.text", "fixture-personal"),
        deny=f.deny(personal, "cc.family.holt.child"),
        family_permit=f.permit(child, "cc.family.holt.child", "fixture-family"),
    )
    f.case(
        "per-principal-child-model",
        ["T13"],
        permit=f.permit(child, "cc.family.holt.child", "fixture-family"),
        deny=f.deny(child, "cc.family.holt.adult"),
        same_team_adult_permit=f.permit(
            adult, "cc.family.holt.adult", "fixture-personal"
        ),
    )
    f.native.call(
        "POST",
        "/key/update",
        {
            "key": child_hash,
            "models": ["cc.family.holt.child", "cc.family.holt.adult"],
            "allowed_routes": ["llm_api_routes"],
            "metadata": {},
            "object_permission": {"models": ["cc.family.holt.adult"]},
        },
    )
    f.controller.run(rotate=False)
    repaired = f.native.key(child_hash)
    require(
        repaired["models"] == ["cc.family.holt.child"]
        and repaired["allowed_routes"] == ["/v1/chat/completions"]
        and repaired["metadata"].get("cc.principal") == "fixture-child",
        "known_key_not_repaired",
    )
    f.case(
        "erased-metadata-and-permission-repair",
        ["T13", "T19"],
        permit=f.permit(child, "cc.family.holt.child", "fixture-family"),
        deny=f.deny(child, "cc.family.holt.adult"),
        retained_protected_native_identity=True,
        native_metadata_repaired=True,
    )
    f.result["phase"] = "management-denial"
    checks = []
    for path, body in (
        ("/key/generate", {"models": ["personal-fixture"], "duration": "1m"}),
        ("/key/update", {"key": f.unowned_hash, "models": []}),
        ("/key/delete", {"keys": [f.unowned_hash]}),
        (
            "/user/new",
            {"user_id": "fixture-escalation-attempt", "auto_create_key": False},
        ),
        (
            "/user/update",
            {"user_id": "fixture-human-native-admin", "user_role": "internal_user"},
        ),
        ("/user/delete", {"user_ids": ["fixture-human-native-admin"]}),
        ("/team/new", {"team_id": "fixture-escalation-team"}),
        ("/team/update", {"team_id": f.unowned_team, "models": []}),
        ("/team/delete", {"team_ids": [f.unowned_team]}),
    ):
        permit = f.permit(personal, "cc.personal.ryan.text", "fixture-personal")
        before = f.counts()
        response = f.client.post(
            path, json=body, headers={"Authorization": "Bearer " + personal}
        )
        require(
            response.status_code in (401, 403),
            "native_admin_inference_key_managed_objects",
        )
        require(
            f.counts() == before and f.native_snapshot() == unowned_before,
            "management_deny_had_effects",
        )
        checks.append(
            {
                "path": path,
                "status": response.status_code,
                "provider_requests": 0,
                "permit": permit,
            }
        )
    for path in (
        "/key/info?key=" + personal_hash,
        "/user/info?user_id=fixture-human-native-admin",
        "/team/info?team_id=" + f.unowned_team,
    ):
        permit = f.permit(personal, "cc.personal.ryan.text", "fixture-personal")
        before = f.counts()
        response = f.client.get(path, headers={"Authorization": "Bearer " + personal})
        require(
            response.status_code in (401, 403) and f.counts() == before,
            "inference_key_read_management_allowed",
        )
        checks.append(
            {
                "method": "GET",
                "path": path.split("?")[0],
                "status": response.status_code,
                "provider_requests": 0,
                "permit": permit,
            }
        )
    admin_after = f.call("GET", "/user/info?user_id=fixture-human-native-admin")
    require(
        admin_after.get("user_info", {}).get("user_role", admin_after.get("user_role"))
        == "proxy_admin",
        "denied_user_update_changed_role",
    )
    before = f.counts()
    control_deny = f.inference(f.control_key, "cc.personal.ryan.text")
    require(
        control_deny.status_code in (401, 403) and f.counts() == before,
        "management_key_allowed_inference",
    )
    f.case(
        "native-management-separation",
        ["T30"],
        human_native_role="proxy_admin",
        management_denials=checks,
        separate_controller_management_status=200,
        separate_controller_inference_status=control_deny.status_code,
    )
    f.result["phase"] = "template-retirement"
    retire_permit = f.permit(retiring, "cc.personal.ryan.text", "fixture-personal")
    f.native.call("POST", "/key/update", {"key": retiring_hash, "metadata": {}})
    f.controller.run(rotate=False)
    f.desired.document["model_templates"]["personal-retiring"]["status"] = "retired"
    del f.records[retiring_hash]
    f.publish()
    f.controller.run(rotate=False)
    require(
        retiring_hash in f.ledger.load()["keys"]
        and f.native_snapshot() == unowned_before,
        "retirement_lost_history_or_changed_unowned",
    )
    f.case(
        "removed-template-native-key-disable",
        ["T19"],
        permit=retire_permit,
        deny=f.deny(retiring, "cc.personal.ryan.text"),
        surviving_runtime_key=f.permit(
            personal, "cc.personal.ryan.text", "fixture-personal"
        ),
        missing_snapshot_entry_retained_as_owned=True,
        unowned_rows_unchanged=True,
    )
    f.result["phase"] = "inventory-fail-closed"
    snapshot_file = f.snapshot_path.read_bytes()
    inventory_file = (f.ledger.path / "ownership.json").read_bytes()
    adverse = []
    for path, saved in (
        (f.snapshot_path, snapshot_file),
        (f.ledger.path / "ownership.json", inventory_file),
    ):
        for corrupt in (False, True):
            if corrupt:
                path.write_text("{}")
                path.chmod(0o600)
            else:
                path.unlink()
            before_ops = len(f.native.operations)
            failure = f.expected_failure(
                lambda: f.controller.run(rotate=False),
                {
                    "protected_file_unavailable",
                    "invalid_snapshot_fields",
                    "invalid_ledger",
                },
            )
            require(
                len(f.native.operations) == before_ops,
                "missing_inventory_used_native_api",
            )
            adverse.append(failure)
            path.write_bytes(saved)
            path.chmod(0o600)
    f.controller.run(rotate=False)
    f.case(
        "missing-corrupt-protected-input",
        ["T19"],
        denies=adverse,
        permit=f.permit(personal, "cc.personal.ryan.text", "fixture-personal"),
        native_mutations=0,
        zero_implicit_reinitialization=True,
    )
    return personal, personal_hash, unowned_before


def exercise_rotation(f):
    f.result["phase"] = "service-publication"
    before = f.counts()
    missing = f.start_consumer()
    require(f.counts() == before, "consumer_read_failure_reached_provider")
    f.controller.run()
    exported = ProtectedSnapshotSource(
        f.controller.service_association_snapshot,
        f.data["installation"],
        f.issuer,
        os.geteuid(),
    ).read(int(time.time()))
    published = ServiceKey.read(f.root / "delivery/key.json", owner_uid=os.geteuid())
    require(
        published.native_key_id in exported.records
        and exported.records[published.native_key_id]["expires_at"]
        == published.expires_at,
        "service_association_not_published",
    )
    first = f.consume()
    require(
        first["requests"][0]["status"] == 200
        and not first["requests"][0].get("ack_error"),
        "service_initial_inference_failed",
    )
    f.controller.run()
    first_key = ServiceKey.read(f.root / "delivery/key.json", owner_uid=os.geteuid())
    time.sleep(2.1)
    f.result["phase"] = "service-atomic-overlap"
    f.consume(count=35, wait=False)
    f.controller.run()
    observed = f.consumer_result()
    require(
        all(r["status"] == 200 for r in observed["requests"]),
        "atomic_publication_torn_read",
    )
    second_key = ServiceKey.read(f.root / "delivery/key.json", owner_uid=os.geteuid())
    require(
        second_key.native_key_id != first_key.native_key_id, "service_key_not_rotated"
    )
    require(
        {first_key.native_key_id, second_key.native_key_id}
        <= {r["native_key_id"] for r in observed["requests"]},
        "running_consumer_did_not_observe_replacement",
    )
    f.controller.run()
    overlap_old = f.permit(first_key.token, "cc.personal.ryan.text", "fixture-personal")
    overlap_new = f.permit(
        second_key.token, "cc.personal.ryan.text", "fixture-personal"
    )
    time.sleep(2.1)
    f.controller.run()
    f.case(
        "atomic-acknowledged-service-rotation",
        ["T29"],
        initial_missing_file=missing["requests"][0],
        live_consumer_same_pid=True,
        successful_concurrent_reads=len(observed["requests"]),
        old_key_during_overlap=overlap_old,
        new_key_during_overlap=overlap_new,
        previous_after_overlap=f.deny(first_key.token, "cc.personal.ryan.text"),
        new_key_after_overlap=f.permit(
            second_key.token, "cc.personal.ryan.text", "fixture-personal"
        ),
    )
    f.result["phase"] = "service-rotation-failure"
    original = f.controller.native

    class Unavailable(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            if (self.server.mode == "reject" and self.path == "/key/generate") or (
                self.server.mode == "retirement" and self.path == "/key/block"
            ):
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            response = f.client.post(
                self.path,
                content=body,
                headers={
                    "Authorization": self.headers.get("Authorization", ""),
                    "Content-Type": "application/json",
                },
            )
            if (
                self.server.mode == "publication"
                and self.path == "/key/generate"
                and response.status_code == 200
            ):
                path = f.root / "delivery/key.json"
                path.rename(f.root / "delivery/last-working.json")
                path.mkdir(mode=0o750)
                os.chown(path, 0, 65532)
            self.send_response(response.status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response.content)))
            self.end_headers()
            self.wfile.write(response.content)

        def do_GET(self):
            response = f.client.get(
                self.path,
                headers={"Authorization": self.headers.get("Authorization", "")},
            )
            self.send_response(response.status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response.content)))
            self.end_headers()
            self.wfile.write(response.content)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Unavailable)
    server.mode = "reject"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        f.controller.native = Native(
            "http://127.0.0.1:" + str(server.server_port), f.control_key
        )
        fail = f.expected_failure(lambda: f.controller.run(), {"native_request_failed"})
        require(
            f.permit(second_key.token, "cc.personal.ryan.text", "fixture-personal")[
                "status"
            ]
            == 200,
            "rotation_failure_revoked_last_key",
        )
    finally:
        f.controller.native = original
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    # Failed /key/generate did not create a native key. Recover only the exact
    # journaled, unpublished intent by verifying native absence with the master.
    pending = f.ledger.load()["services"]["whiskey-service"]["pending"]
    require(pending is not None, "rotation_failure_not_journaled")
    missing_key = f.client.get(
        "/key/info",
        params={"key": pending["native_key_id"]},
        headers={"Authorization": "Bearer " + f.master},
    )
    f.result["absent_native_key_status"] = missing_key.status_code
    f.result["phase"] = "service-failed-issuance-recovery"
    f.controller.run()
    f.case(
        "service-native-rotation-failure",
        ["T29"],
        deny=fail,
        permit=f.permit(second_key.token, "cc.personal.ryan.text", "fixture-personal"),
        last_key_not_revoked=True,
        direct_provider_fallback=False,
    )
    f.result["phase"] = "service-publication-failure"
    path = f.root / "delivery/key.json"
    backup = f.root / "delivery/last-working.json"
    path.rename(backup)
    path.mkdir(mode=0o750)
    os.chown(path, 0, 65532)
    # A real filesystem publication failure, not a mocked successful delivery.
    try:
        fail = f.expected_failure(
            lambda: f.controller.run(), {"untrusted_file", "protected_file_unavailable"}
        )
        read_before = f.counts()
        unreadable = f.consume()["requests"][0]
        require(
            unreadable["status"] == "read-failed" and f.counts() == read_before,
            "read_failure_fell_back",
        )
        last_permit = f.permit(
            second_key.token, "cc.personal.ryan.text", "fixture-personal"
        )
    finally:
        path.rmdir()
        backup.rename(path)
    f.case(
        "service-file-read-failure",
        ["T29"],
        deny=fail,
        consumer=unreadable,
        permit=last_permit,
        last_key_not_revoked=True,
        direct_provider_fallback=False,
    )
    server = ThreadingHTTPServer(("127.0.0.1", 0), Unavailable)
    server.mode = "publication"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        f.controller.native = Native(
            "http://127.0.0.1:" + str(server.server_port), f.control_key
        )
        publication_failed = f.expected_failure(
            lambda: f.controller.run(), {"atomic_publication_failed"}
        )
        require(backup.exists() and path.is_dir(), "publication_fault_not_executed")
        last_permit = f.permit(
            second_key.token, "cc.personal.ryan.text", "fixture-personal"
        )
    finally:
        f.controller.native = original
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        if path.is_dir() and backup.exists():
            path.rmdir()
            backup.rename(path)
    f.controller.run()
    f.case(
        "atomic-publication-failure",
        ["T29"],
        deny=publication_failed,
        permit=last_permit,
        unpublished_native_key_retired=True,
        last_working_key_preserved=True,
    )
    f.controller.run()
    pending_key = ServiceKey.read(path, owner_uid=os.geteuid())
    ack_path = f.root / "acks/key.json"
    bad_ack = {
        "schema_version": 1,
        "kind": "atrium.litellm-service-key-ack",
        "installation": f.data["installation"],
        "issuer": f.issuer,
        "template_id": "whiskey-service",
        "native_key_id": second_key.native_key_id,
        "publication_id": pending_key.publication_id,
        "acknowledged_at": int(time.time()),
    }
    ack_path.write_bytes(canonical(bad_ack))
    os.chown(ack_path, 65532, 0)
    ack_path.chmod(0o600)
    f.result["phase"] = "service-acknowledgement-failure"
    failed_ack = f.expected_failure(
        lambda: f.controller.run(), {"service_ack_identity_mismatch"}
    )
    working = f.permit(second_key.token, "cc.personal.ryan.text", "fixture-personal")
    recovered = f.consume()
    require(recovered["requests"][0]["status"] == 200, "service_ack_recovery_failed")
    f.controller.run()
    f.case(
        "identity-bound-acknowledgement",
        ["T29"],
        deny=failed_ack,
        previous_still_works=working,
        permit=recovered["requests"][0],
        filename_only_acknowledgement_rejected=True,
    )
    f.result["phase"] = "native-retirement-failure"
    time.sleep(2.1)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Unavailable)
    server.mode = "retirement"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        f.controller.native = Native(
            "http://127.0.0.1:" + str(server.server_port), f.control_key
        )
        retire_failed = f.expected_failure(
            lambda: f.controller.run(), {"native_request_failed"}
        )
        old_permit = f.permit(
            second_key.token, "cc.personal.ryan.text", "fixture-personal"
        )
        current_permit = f.consume()["requests"][0]
        require(current_permit["status"] == 200, "retirement_failure_lost_current_key")
    finally:
        f.controller.native = original
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    f.controller.run()
    f.case(
        "native-retirement-failure-retry",
        ["T29"],
        deny=retire_failed,
        old_before_recovery=old_permit,
        current_during_failure=current_permit,
        old_after_recovery=f.deny(second_key.token, "cc.personal.ryan.text"),
        current_after_recovery=f.consume()["requests"][0],
    )


def exercise_alias_denial(f, personal, unowned_before):
    f.result["phase"] = "owned-alias-update"
    before_id = f.ledger.load()["aliases"]["cc.family.holt.adult::family-adult"][
        "native_id"
    ]
    updated = copy.deepcopy(f.desired.document)
    updated["model_backends"]["family-adult"]["model"] = "openai/fixture-family"
    f.desired = Desired.parse(updated)
    f.controller.desired = f.desired
    before = (f.ledger.path / "ownership.json").read_bytes()
    dry_run = f.controller.run(dry_run=True, rotate=False)
    require(
        any(a["action"] == "update-alias" for a in dry_run["actions"]),
        "alias_update_not_planned",
    )
    require(
        before == (f.ledger.path / "ownership.json").read_bytes(),
        "alias_update_dry_run_mutated_ledger",
    )
    f.controller.run(rotate=False)
    require(
        f.ledger.load()["aliases"]["cc.family.holt.adult::family-adult"]["native_id"]
        == before_id,
        "alias_update_changed_identity",
    )
    require(
        f.native_snapshot() == unowned_before, "alias_update_changed_unowned_objects"
    )
    f.case(
        "owned-alias-update",
        ["T22"],
        stable_native_model_id=True,
        unowned_rows_unchanged=True,
        permit=f.permit(f.adult_key, "cc.family.holt.adult", "fixture-family"),
    )
    f.result["phase"] = "alias-account-denial"
    permit = f.permit(personal, "cc.personal.ryan.text", "fixture-personal")
    original = f.desired
    bad = copy.deepcopy(original.document)
    bad["model_backends"]["personal-text"]["account"] = "foreign-account"
    native_before = len(f.native.operations)
    ledger_before = (f.ledger.path / "ownership.json").read_bytes()
    static_failure = f.expected_failure(
        lambda: Desired.parse(bad), {"foreign_backend_account"}
    )
    require(
        native_before == len(f.native.operations)
        and ledger_before == (f.ledger.path / "ownership.json").read_bytes(),
        "rejected_template_mutated_state",
    )
    own = f.ledger.load()
    personal_alias = own["aliases"]["cc.personal.ryan.text::personal-text"]
    expected = personal_alias["expected"]
    altered = {
        "model_name": expected["model_name"],
        "litellm_params": {
            **expected["litellm_params"],
            "litellm_credential_name": own["credentials"]["family-model"]["native_id"],
        },
        "model_info": {
            "id": personal_alias["native_id"],
            "mode": "chat",
            **expected["metadata"],
        },
    }
    f.call("POST", "/model/update", altered)
    native_before = len(f.native.operations)
    owned_drift = f.expected_failure(
        lambda: f.controller.run(rotate=False), {"native_alias_backend_drift"}
    )
    require(
        all(op["method"] == "GET" for op in f.native.operations[native_before:])
        and ledger_before == (f.ledger.path / "ownership.json").read_bytes(),
        "owned_account_drift_was_silently_repaired",
    )
    f.call(
        "POST",
        "/model/update",
        {**altered, "litellm_params": expected["litellm_params"]},
    )
    f.case(
        "owned-native-account-drift",
        ["T22"],
        deny=owned_drift,
        permit=f.permit(personal, "cc.personal.ryan.text", "fixture-personal"),
        native_mutations_on_denial=0,
        ledger_mutations_on_denial=0,
    )
    foreign_id = "fixture-foreign-alias-" + secrets.token_hex(6)
    f.call(
        "POST",
        "/model/new",
        {
            "model_name": "cc.personal.ryan.text",
            "litellm_params": {
                "model": "openai/fixture-family",
                "api_base": "http://" + f.data["provider"] + ":8000/v1",
                "litellm_credential_name": own["credentials"]["family-model"][
                    "native_id"
                ],
            },
            "model_info": {
                "id": foreign_id,
                "mode": "chat",
                "cc.owner": "command-center",
                "cc.domain": "family:holt",
                "cc.account": "foreign-account",
            },
        },
    )
    native_before = len(f.native.operations)
    fail = f.expected_failure(
        lambda: f.controller.run(rotate=False), {"unowned_alias_collision"}
    )
    require(
        all(op["method"] == "GET" for op in f.native.operations[native_before:]),
        "foreign_alias_was_rewritten",
    )
    require(
        ledger_before == (f.ledger.path / "ownership.json").read_bytes(),
        "alias_denial_changed_ledger",
    )
    require(f.native_snapshot() == unowned_before, "alias_denial_changed_unowned_state")
    f.case(
        "native-alias-backend-account-exclusivity",
        ["T22"],
        permit=permit,
        invalid_desired_account=static_failure,
        same_name_foreign_native_binding=fail,
        native_mutations_on_denial=0,
        ledger_mutations_on_denial=0,
        unowned_rows_unchanged=True,
    )


def run(data):
    result = {
        "status": "running",
        "cases": [],
        "phase": "fixture-setup",
        "native_version": "1.99.1",
        "admission_hook": "not-implemented-N05",
        "resolver_issuance": "protected fixture publisher, not R06 broker",
        "protocols": ["POST /v1/chat/completions non-streaming"],
        "workers": 1,
        "cache": False,
        "gate_scope": {
            "T5": "controller/native slice; R06 integration pending",
            "T13": "controller/native slice; R06 integration pending",
            "T19": "controller/native slice; integrated N05/R06 gate pending",
            "T22": "owned native bindings and desired expectations",
            "T29": "actual controller plus running fixture consumer; W03 integration pending",
            "T30": "native management restriction with human proxy_admin; N05 endpoint matrix pending",
        },
    }
    fixture = None
    try:
        fixture = Fixture(data, result)
        personal, _identity, unowned = exercise_basics(fixture)
        exercise_rotation(fixture)
        exercise_alias_denial(fixture, personal, unowned)
        result["provider_totals"] = fixture.counts()
        result["status"] = "passed"
        result["phase"] = "complete"
    except ControllerError as exc:
        result.update(status="failed", code=exc.code)
    finally:
        if fixture:
            fixture.close()
    return result
