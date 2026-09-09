"""Actual producer/reader APIs under different kernel UIDs; no gateway or issuer double."""

import ctypes
import hashlib
import json
import os
import secrets
import stat
import time
import traceback
from pathlib import Path

PUBLISHER = 62101
CONTROLLER = 62102
READER = 62103
UNRELATED = 62104
CONSUMER = 62105
READ_GID = 62201
TOKEN_GID = 62202
ROOT = Path("/run/atrium-publications/uid-proof")


def as_user(uid, groups, operation):
    return collect(start_user(uid, groups, operation))


def start_user(uid, groups, operation):
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            for capability in range(64):
                libc.prctl(24, capability, 0, 0, 0)
            if libc.prctl(38, 1, 0, 0, 0) != 0:
                raise RuntimeError("no_new_privileges_failed")
            os.setgroups(groups)
            os.setgid(uid)
            os.setuid(uid)
            result = operation()
            response = {"passed": True, "result": result}
        except Exception as error:
            frame = traceback.extract_tb(error.__traceback__)[-1]
            response = {
                "passed": False,
                "error": getattr(error, "code", type(error).__name__),
                "location": f"{Path(frame.filename).name}:{frame.lineno}",
            }
            if type(error).__name__ == "ValidationError":
                response["fields"] = [
                    {"location": list(item["loc"]), "type": item["type"]}
                    for item in error.errors(
                        include_input=False, include_context=False, include_url=False
                    )
                ]
        with os.fdopen(write_fd, "w") as stream:
            json.dump(response, stream)
        os._exit(0)
    os.close(write_fd)
    return pid, read_fd


def collect(child):
    pid, read_fd = child
    with os.fdopen(read_fd) as stream:
        response = json.load(stream)
    _, status = os.waitpid(pid, 0)
    if status != 0:
        raise AssertionError("publication_child_failed")
    return response


def require(response):
    if not response["passed"]:
        raise AssertionError(
            "publication_actor_refused_"
            + response["error"]
            + "_"
            + response.get("location", "")
            + ("_" + json.dumps(response["fields"]) if "fields" in response else "")
        )
    return response["result"]


def privilege_state():
    result = {}
    for line in Path("/proc/self/status").read_text().splitlines():
        if line.startswith(("Cap", "NoNewPrivs")):
            name, value = line.split(":", 1)
            result[name] = value.strip()
    assert result["NoNewPrivs"] == "1"
    assert all(
        int(value, 16) == 0 for name, value in result.items() if name.startswith("Cap")
    )
    return result


def publisher_step(initial=False):
    from pydantic import SecretStr
    from atrium_profiles.runtime import atomic_private_write
    from atrium_resolver.config import Authority, Bootstrap, Settings
    from atrium_resolver.litellm_broker import LiteLLMBroker, ModelKeyMetadata
    from atrium_resolver.litellm_config import LiteLLMSettings
    from atrium_resolver.manifests import _binding_digest, _identity_digest
    from atrium_resolver.policy import AuthorizationRequest, PolicyEngine, PolicySeed
    from atrium_resolver.state import AuthenticatedIdentity, State

    document = json.loads((ROOT / "policy.json").read_text())
    source = document["principals"]["fixture-admin"]["bindings"][0]["authority"]
    authorities = tuple(
        Authority(
            id=name,
            **{field: value[field] for field in ("issuer", "audience", "jwks_uri")},
        )
        for name, value in document["authorities"].items()
    )
    authority = next(value for value in authorities if value.id == source)
    private = ROOT / "resolver-private"
    settings = Settings(
        authorities=authorities,
        state_directory=private / "state",
        policy_path=ROOT / "policy.json",
        isolated_harness=True,
    )
    state = State(settings.state_directory)
    try:
        state.configure_authorities(settings.authorities)
        policy = PolicyEngine(settings, state)
        principal = "fixture-admin"
        subject = document["principals"][principal]["bindings"][0]["subject"]
        request = AuthorizationRequest.model_validate_json(
            json.dumps(
                {
                    "domain": "personal:fixture",
                    "instance": "personal-models",
                    "template_id": "personal-client",
                    "scopes": [],
                    "permissions": [],
                    "models": document["model_templates"]["personal-client"]["models"],
                    "routes": document["model_templates"]["personal-client"]["routes"],
                    "budget": document["model_templates"]["personal-client"]["budget"],
                    "lifetime_seconds": 300,
                }
            )
        )
        if initial:
            enrollment = Bootstrap.model_validate_json(
                json.dumps(
                    {
                        "principals": [
                            {
                                "id": principal,
                                "display_name": "Synthetic publisher principal",
                                "kind": "human",
                                "roles": ["admin"],
                            }
                        ],
                        "identities": [
                            {
                                "principal": principal,
                                "authority": source,
                                "subject": subject,
                            }
                        ],
                    }
                )
            )
            policy.validate_enrollment(enrollment)
            state.bootstrap(enrollment)
            policy.seed_local(
                PolicySeed.model_validate_json(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "administrator": principal,
                            "grants": [
                                {
                                    "id": "publication-seed",
                                    "principal": principal,
                                    "authority": source,
                                    "subject": subject,
                                    "request": request.model_dump(mode="json"),
                                    "expires_at": None,
                                    "can_delegate": False,
                                }
                            ],
                        }
                    )
                )
            )
        now = int(time.time())
        identity = AuthenticatedIdentity(
            principal=principal,
            authority=source,
            issuer=authority.issuer,
            subject=subject,
            roles=frozenset({"admin"}),
            credential_id="publication-fixture-identity",
            issued_at=now,
            expires_at=now + 900,
        )
        decision = policy.authorize(identity, request)
        configured = LiteLLMSettings(
            endpoint=document["deployments"]["models"]["endpoint"],
            installation="publication-uid-fixture",
            runtime_directory=private / "broker",
            controller_key_file=private / "keys/control",
            controller_inventory_file=ROOT / "controller-public/native-bindings.json",
            controller_desired_state_path=ROOT / "desired.json",
            controller_publisher_uid=CONTROLLER,
            publication_directory=ROOT / "resolver-public",
            publication_reader_gid=READ_GID,
        )
        broker = LiteLLMBroker(policy, configured)
        try:
            operation = secrets.token_hex(32)
            raw = SecretStr("sk-" + secrets.token_urlsafe(32))
            fingerprint = hashlib.sha256(raw.get_secret_value().encode()).hexdigest()
            metadata = ModelKeyMetadata(
                operation_id=operation,
                identity_sha256=_identity_digest(identity),
                binding_sha256=_binding_digest(decision),
                grant_id=decision.grant_id,
                policy_revision=decision.policy_revision,
                instance=decision.instance,
                audience=decision.audience,
                team=decision.team,
                models=decision.models,
                routes=decision.routes,
                budget=decision.budget,
                expected=broker._payload(decision, operation, decision.team, now + 300),
                deadline=now + 300,
                status="reserved",
            )
            with state.transaction(write=True) as connection:
                connection.execute(
                    "INSERT INTO credential_associations "
                    "(issuer, credential_id, credential_sha256, principal_id, authority_id, domain, target, "
                    "permissions_json, template_id, issued_at, expires_at, admin_outage_eligible) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        configured.endpoint,
                        "sha256:" + fingerprint,
                        fingerprint,
                        principal,
                        source,
                        decision.domain,
                        decision.target,
                        metadata.model_dump_json(),
                        decision.template_id,
                        now,
                        now + 300,
                        int(decision.admin_outage_eligible),
                    ),
                )
            atomic_private_write(
                broker.directory / (fingerprint + ".key"),
                raw.get_secret_value().encode(),
            )
            assert (
                broker._read_escrow(fingerprint).get_secret_value()
                == raw.get_secret_value()
            )
            broker._publish_inventory()
            snapshot = json.loads(
                (ROOT / "resolver-public/admission-associations.json").read_text()
            )
            return {
                "count": len(snapshot["credentials"]),
                "generation": snapshot["generation"],
                "privileges": privilege_state(),
            }
        finally:
            broker.close()
    finally:
        state.close()


def controller_step(initial=False):
    from atrium_litellm.controller import Controller
    from atrium_litellm.desired import Desired
    from atrium_litellm.ledger import Ledger
    from atrium_litellm.native import Native

    desired = Desired.read(ROOT / "desired.json")
    ledger = Ledger(
        ROOT / "controller-private",
        "publication-uid-fixture",
        desired.document["deployments"]["models"]["endpoint"],
    )
    if initial:
        ledger.initialize()
    native = Native(ledger.issuer, "sk-" + secrets.token_urlsafe(32))
    controller = Controller(
        desired,
        ledger,
        native,
        None,
        {},
        bindings_snapshot=ROOT / "controller-public/native-bindings.json",
        service_association_snapshot=ROOT
        / "controller-public/service-associations.json",
        publication_reader_gid=READ_GID,
    )
    now = int(time.time())
    with ledger.locked():
        for index, (name, _) in enumerate(desired.teams.items()):
            ledger.state["teams"][name] = {
                "native_id": "publication-team-" + str(index),
                "status": "owned",
                "provenance": "controller-created",
            }
        for name, declaration in desired.aliases.items():
            for backend in declaration["backends"]:
                source = desired.document["model_backends"][backend]
                key = name + ":" + backend
                ledger.state["aliases"][key] = {
                    "native_id": "publication-model-" + backend,
                    "status": "owned",
                    "provenance": "controller-created",
                    "alias": name,
                    "backend": backend,
                    "expected": {
                        "litellm_params": {
                            "model": source["model"],
                            "api_base": "https://provider.atrium.invalid/v1",
                            "litellm_credential_name": "publication-"
                            + source["credential"],
                        },
                        "metadata": {
                            "cc.domain": source["domain"],
                            "cc.provider": source["provider"],
                            "cc.account": source["account"],
                            "cc.credential": source["credential"],
                        },
                    },
                }
        template = desired.templates["whiskey-service"]
        fingerprint = secrets.token_hex(32)
        ledger.state["keys"][fingerprint] = {
            "source": "controller",
            "association": {
                "issuer": ledger.issuer,
                "credential_id": fingerprint,
                "native_key_id": fingerprint,
                "principal_id": template["service"]["principal"],
                "authority_id": "controller",
                "domain": template["domain"],
                "template_id": "whiskey-service",
                "native_team_id": ledger.state["teams"][template["team"]]["native_id"],
                "issued_at": now,
                "expires_at": now + 300,
                "device_id": None,
                "state": "active",
                "effective_limits": {
                    "models": template["models"],
                    "routes": template["routes"],
                    "budget": template["budget"],
                },
            },
        }
        ledger.save()
        controller.publish_bindings(now)
        controller.publish_service_associations(now)
        return {
            "count": len(ledger.state["keys"]),
            "generation": ledger.state["revision"],
            "privileges": privilege_state(),
        }


def read_current():
    from atrium_litellm.associations import ProtectedSnapshotSource
    from atrium_admission.models import Producer, Settings
    from atrium_admission.producers import read_producer
    from atrium_resolver.litellm_inventory import read_document
    from atrium_resolver.policy_schema import PolicyDocument

    policy = PolicyDocument.model_validate_json((ROOT / "policy.json").read_bytes())
    issuer = policy.deployments["models"].endpoint
    producers = (
        Producer(
            id="resolver",
            kind="resolver",
            path=ROOT / "resolver-public/admission-associations.json",
            publisher_uid=PUBLISHER,
        ),
        Producer(
            id="services",
            kind="controller-service",
            path=ROOT / "controller-public/service-associations.json",
            publisher_uid=CONTROLLER,
        ),
    )
    settings = Settings(
        schema_version=1,
        isolated=True,
        installation="publication-uid-fixture",
        issuer=issuer,
        runtime_directory=ROOT / "reader-private",
        policy_path=ROOT / "policy.json",
        policy_publisher_uid=0,
        producers=producers,
        deny_issuer="https://resolver.atrium.invalid",
        deny_url="https://resolver.atrium.invalid/v1/deny-feed",
        jwks_url="https://resolver.atrium.invalid/.well-known/jwks.json",
    )
    results = [
        read_producer(producer, settings, policy, int(time.time()))
        for producer in producers
    ]
    controller = read_document(
        ROOT / "controller-public/native-bindings.json", publisher_uid=CONTROLLER
    )
    association = read_document(
        ROOT / "resolver-public/associations.json", publisher_uid=PUBLISHER
    )
    n04 = ProtectedSnapshotSource(
        ROOT / "resolver-public/associations.json",
        "publication-uid-fixture",
        issuer,
        PUBLISHER,
    ).read(int(time.time()))
    # Each read is atomic, but a valid replacement may land between separate reader calls.
    assert n04.records
    files = [producer.path for producer in producers] + [
        ROOT / "controller-public/native-bindings.json",
        ROOT / "resolver-public/associations.json",
    ]
    modes = [
        {
            "owner": path.stat().st_uid,
            "group": path.stat().st_gid,
            "mode": oct(stat.S_IMODE(path.stat().st_mode)),
        }
        for path in files
    ]
    assert all(row["group"] == READ_GID and row["mode"] == "0o640" for row in modes)
    return {
        "counts": [len(result[3]) for result in results],
        "generations": [result[0] for result in results],
        "bindings_generation": controller["generation"],
        "controller_rows": len(association["associations"]),
        "n04_rows": len(n04.records),
        "files": modes,
        "privileges": privilege_state(),
    }


def forbidden_access():
    paths = (
        ROOT / "resolver-public/admission-associations.json",
        ROOT / "controller-public/native-bindings.json",
        ROOT / "resolver-private/state/state.sqlite3",
    )
    refused = []
    for path in paths:
        try:
            path.read_bytes()
        except PermissionError:
            refused.append(True)
        else:
            refused.append(False)
    return refused


def reader_cannot_modify_or_read_custody():
    denied = []
    for path in (
        ROOT / "resolver-public/associations.json",
        ROOT / "controller-public/native-bindings.json",
    ):
        try:
            with path.open("ab") as stream:
                stream.write(b"invalid")
        except PermissionError:
            denied.append(True)
        else:
            denied.append(False)
    for path in (ROOT / "resolver-private/broker", ROOT / "controller-private"):
        try:
            list(path.iterdir())
        except PermissionError:
            denied.append(True)
        else:
            denied.append(False)
    publication = json.loads(
        (ROOT / "resolver-public/admission-associations.json").read_text()
    )
    escrow = (
        ROOT
        / "resolver-private/broker"
        / (publication["credentials"][0]["native_key_id"] + ".key")
    )
    for path in (escrow, ROOT / "controller-private/ownership.json"):
        try:
            path.read_bytes()
        except PermissionError:
            denied.append(True)
        else:
            denied.append(False)
    return denied


def concurrent_reader():
    previous = [0, 0]
    reads = 0
    while not (ROOT / "stop-reader").exists():
        current = read_current()["generations"]
        assert all(
            after >= before for after, before in zip(current, previous, strict=True)
        )
        previous = current
        reads += 1
    return {"complete_reads": reads, "generations": previous}


def fault_matrix(publisher, directory, filename, update):
    path = ROOT / directory / filename
    rows = []
    for fault in (
        "directory-owner",
        "directory-group",
        "directory-mode",
        "owner",
        "group",
        "mode",
        "symlink",
        "hardlink",
        "partial",
    ):
        body = path.read_bytes()
        if fault == "directory-owner":
            os.chown(path.parent, UNRELATED, READ_GID)
        elif fault == "directory-group":
            os.chown(path.parent, publisher, UNRELATED)
        elif fault == "directory-mode":
            path.parent.chmod(0o2770)
        elif fault == "owner":
            os.chown(path, UNRELATED, READ_GID)
        elif fault == "group":
            os.chown(path, publisher, UNRELATED)
        elif fault == "mode":
            path.chmod(0o660)
        elif fault == "symlink":
            path.rename(path.with_name("preserved-output"))
            path.symlink_to(path.with_name("preserved-output"))
        elif fault == "hardlink":
            os.link(path, path.with_name("unexpected-link"))
        else:
            path.write_bytes(b'{"generation":')
        reader = as_user(READER, [READ_GID], read_current)
        writer = as_user(publisher, [READ_GID], update)
        assert not reader["passed"] and not writer["passed"], (
            "unsafe_publication_not_refused"
        )
        if path.is_symlink():
            path.unlink()
            path.with_name("preserved-output").rename(path)
        path.with_name("unexpected-link").unlink(missing_ok=True)
        os.chown(path.parent, publisher, READ_GID)
        path.parent.chmod(0o2750)
        path.write_bytes(body)
        os.chown(path, publisher, READ_GID)
        path.chmod(0o640)
        require(as_user(publisher, [READ_GID], update))
        require(as_user(READER, [READ_GID], read_current))
        rows.append(
            {
                "fault": fault,
                "reader_refused": True,
                "publisher_refused": True,
                "recovery_permitted": True,
            }
        )
    assert not as_user(publisher, [], update)["passed"], (
        "undeclared_publisher_group_not_refused"
    )
    rows.append({"fault": "publisher-not-in-reader-group", "publisher_refused": True})
    return rows


def failed_public_write(update):
    actual = os.fsync

    def fail_public(descriptor):
        if stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o640:
            raise OSError("synthetic_public_stage_fsync_failure")
        return actual(descriptor)

    os.fsync = fail_public
    try:
        return update()
    finally:
        os.fsync = actual


def delivery_fixture():
    from types import SimpleNamespace
    from atrium_litellm.rotation import Delivery

    controller = SimpleNamespace(
        desired=SimpleNamespace(
            templates={
                "whiskey-service": {
                    "service": {
                        "runtime_key_path": str(ROOT / "token-delivery/live.json")
                    }
                }
            }
        ),
        service_delivery={
            "whiskey-service": {
                "ack_path": str(ROOT / "token-ack/ack.json"),
                "consumer_uid": CONSUMER,
                "consumer_gid": TOKEN_GID,
            }
        },
        ledger=SimpleNamespace(
            installation="publication-uid-fixture",
            issuer="https://models.atrium.invalid",
            state={"services": {"whiskey-service": {}}},
        ),
    )
    return Delivery(controller, "whiskey-service")


def publish_service_key():
    from atrium_litellm.rotation import ServiceKey

    delivery = delivery_fixture()
    raw = "sk-" + secrets.token_urlsafe(32)
    key = ServiceKey(
        installation=delivery.controller.ledger.installation,
        issuer=delivery.controller.ledger.issuer,
        template_id="whiskey-service",
        native_key_id=hashlib.sha256(raw.encode()).hexdigest(),
        publication_id=secrets.token_hex(16),
        expires_at=int(time.time()) + 300,
        token=raw,
    )
    delivery.publish(key)
    return {
        "native_key_id": key.native_key_id,
        "publication_id": key.publication_id,
        "created_at": int(time.time()),
    }


def acknowledge_service_key():
    from atrium_litellm.rotation import ServiceKey

    delivery = delivery_fixture()
    key = ServiceKey.read(delivery.path, owner_uid=CONTROLLER)
    key.acknowledge(delivery.ack_path, group=TOKEN_GID)
    return {"publication_id": key.publication_id, "token_not_exported": True}


def check_ack(slot, expected):
    assert (
        delivery_fixture().acknowledged(slot, int(time.time()), missing_ok=True)
        is expected
    )
    return True


def no_service_key_access():
    try:
        (ROOT / "token-delivery/live.json").read_bytes()
    except PermissionError:
        return True
    return False


def run():
    ROOT.mkdir(mode=0o755)
    source = Path("/run/atrium-publications/project/resolver/fixtures")
    (ROOT / "policy.json").write_bytes((source / "policy.generated.json").read_bytes())
    (ROOT / "desired.json").write_bytes(
        (source / "litellm.generated.json").read_bytes()
    )
    for name, owner, group, mode in (
        ("resolver-private", PUBLISHER, PUBLISHER, 0o700),
        ("controller-private", CONTROLLER, CONTROLLER, 0o700),
        ("reader-private", READER, READER, 0o700),
        ("resolver-public", PUBLISHER, READ_GID, 0o2750),
        ("controller-public", CONTROLLER, READ_GID, 0o2750),
        ("token-delivery", CONTROLLER, TOKEN_GID, 0o2750),
        ("token-ack", CONSUMER, TOKEN_GID, 0o2750),
    ):
        directory = ROOT / name
        directory.mkdir(mode=mode)
        os.chown(directory, owner, group)
        directory.chmod(mode)
    first = require(as_user(PUBLISHER, [READ_GID], lambda: publisher_step(True)))
    second = require(as_user(CONTROLLER, [READ_GID], lambda: controller_step(True)))
    read = require(as_user(READER, [READ_GID], read_current))
    assert read["counts"] == [1, 1]
    assert require(as_user(UNRELATED, [], forbidden_access)) == [True, True, True]
    assert (
        require(as_user(READER, [READ_GID], reader_cannot_modify_or_read_custody))
        == [True] * 6
    )
    initial = read["generations"]
    concurrent = start_user(READER, [READ_GID], concurrent_reader)
    try:
        for _ in range(5):
            require(as_user(PUBLISHER, [READ_GID], publisher_step))
            require(as_user(CONTROLLER, [READ_GID], controller_step))
            read = require(as_user(READER, [READ_GID], read_current))
    finally:
        (ROOT / "stop-reader").touch()
        concurrency = require(collect(concurrent))
    assert concurrency["complete_reads"] > 1
    assert read["counts"] == [6, 6] and all(
        after > before
        for after, before in zip(read["generations"], initial, strict=True)
    )
    faults = {
        "resolver": fault_matrix(
            PUBLISHER, "resolver-public", "admission-associations.json", publisher_step
        ),
        "controller": fault_matrix(
            CONTROLLER,
            "controller-public",
            "service-associations.json",
            controller_step,
        ),
    }
    failures = []
    for publisher, directory, update in (
        (PUBLISHER, "resolver-public", publisher_step),
        (CONTROLLER, "controller-public", controller_step),
    ):
        paths = sorted((ROOT / directory).glob("*.json"))
        before = {path.name: path.read_bytes() for path in paths}
        result = as_user(publisher, [READ_GID], lambda: failed_public_write(update))
        assert not result["passed"]
        assert before == {path.name: path.read_bytes() for path in paths}
        require(as_user(READER, [READ_GID], read_current))
        require(as_user(publisher, [READ_GID], update))
        require(as_user(READER, [READ_GID], read_current))
        failures.append(
            {
                "publisher": publisher,
                "working_output_and_age_retained": True,
                "recovery_permitted": True,
            }
        )
    key_slot = require(as_user(CONTROLLER, [TOKEN_GID], publish_service_key))
    require(as_user(CONTROLLER, [TOKEN_GID], lambda: check_ack(key_slot, False)))
    require(as_user(CONSUMER, [TOKEN_GID], acknowledge_service_key))
    require(as_user(CONTROLLER, [TOKEN_GID], lambda: check_ack(key_slot, True)))
    assert require(as_user(READER, [READ_GID], no_service_key_access))
    assert require(as_user(UNRELATED, [], no_service_key_access))
    replaced = require(as_user(CONTROLLER, [TOKEN_GID], publish_service_key))
    assert replaced["publication_id"] != key_slot["publication_id"]
    assert not as_user(CONTROLLER, [TOKEN_GID], lambda: check_ack(replaced, True))[
        "passed"
    ]
    require(as_user(CONSUMER, [TOKEN_GID], acknowledge_service_key))
    require(as_user(CONTROLLER, [TOKEN_GID], lambda: check_ack(replaced, True)))
    return {
        "uids": {
            "resolver": PUBLISHER,
            "controller": CONTROLLER,
            "reader": READER,
            "unrelated": UNRELATED,
        },
        "reader_gid": READ_GID,
        "resolver": first,
        "controller": second,
        "final_reader": read,
        "atomic_replacement_rounds": 5,
        "unrelated_denied": True,
        "reader_write_and_custody_denied": True,
        "concurrent_reader": concurrency,
        "faults": faults,
        "publisher_failures": failures,
        "unchanged_service_delivery": {
            "consumer_uid": CONSUMER,
            "separate_gid": TOKEN_GID,
            "new_publication_requires_new_ack": True,
            "metadata_readers_cannot_read_service_keys": True,
        },
    }
