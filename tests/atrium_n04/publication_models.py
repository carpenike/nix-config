"""Run the existing combined native driver and independent OS-bound metadata readers."""

import json
import os
import stat
import time
import traceback
from pathlib import Path

import httpx
from pydantic import SecretStr

from publication_uids import (
    PUBLISHER,
    READER,
    READ_GID,
    UNRELATED,
    as_user,
    collect,
    privilege_state,
    require,
    start_user,
)

ROOT = Path("/run/atrium-publication-models")
PUBLIC = ROOT / "publications"


def paths():
    return (
        PUBLIC / "resolver/admission-associations.json",
        PUBLIC / "resolver/associations.json",
        PUBLIC / "controller/native-bindings.json",
        PUBLIC / "controller/service-associations.json",
    )


def read_publications(document):
    from atrium_admission.models import Producer, Settings
    from atrium_admission.producers import read_producer
    from atrium_litellm.associations import ProtectedSnapshotSource
    from atrium_resolver.litellm_inventory import read_document
    from atrium_resolver.policy_schema import PolicyDocument

    policy = PolicyDocument.model_validate_json(json.dumps(document))
    issuer = policy.deployments["models"].endpoint
    producers = (
        Producer(
            id="resolver",
            kind="resolver",
            path=paths()[0],
            publisher_uid=PUBLISHER,
        ),
        Producer(
            id="services",
            kind="controller-service",
            path=paths()[3],
            publisher_uid=PUBLISHER,
        ),
    )
    settings = Settings(
        schema_version=1,
        isolated=True,
        installation="atrium-r06-fixture",
        issuer=issuer,
        runtime_directory=ROOT / "reader",
        policy_path=ROOT / "policy.json",
        policy_publisher_uid=PUBLISHER,
        producers=producers,
        deny_issuer="https://resolver.atrium.invalid",
        deny_url="https://resolver.atrium.invalid/v1/deny-feed",
        jwks_url="https://resolver.atrium.invalid/.well-known/jwks.json",
    )
    candidates = [
        read_producer(producer, settings, policy, int(time.time()))
        for producer in producers
    ]
    associations = ProtectedSnapshotSource(
        paths()[1], settings.installation, issuer, PUBLISHER
    ).read(int(time.time()))
    bindings = read_document(paths()[2], publisher_uid=PUBLISHER)
    metadata = []
    for path in paths():
        info = path.stat()
        assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (
            PUBLISHER,
            READ_GID,
            0o640,
        )
        metadata.append(
            {
                "uid": info.st_uid,
                "gid": info.st_gid,
                "mode": oct(stat.S_IMODE(info.st_mode)),
            }
        )
    assert candidates[0][3] and associations.records and bindings["teams"]
    return {
        "generations": [candidate[0] for candidate in candidates],
        "resolver_credentials": len(candidates[0][3]),
        "n04_associations": len(associations.records),
        "binding_generation": bindings["generation"],
        "files": metadata,
        "privileges": privilege_state(),
    }


def no_read_access():
    for path in (*paths(), ROOT / "private/management"):
        try:
            path.read_bytes()
        except PermissionError:
            continue
        return False
    return True


def no_write_or_private_access():
    for path in paths():
        try:
            with path.open("ab"):
                return False
        except PermissionError:
            pass
    for path in (ROOT / "private/management", ROOT / "private/signing"):
        try:
            if path.is_dir():
                list(path.iterdir())
            else:
                path.read_bytes()
        except PermissionError:
            continue
        return False
    return True


def run(data):
    PUBLIC.mkdir(mode=0o755)
    for path, uid, gid, mode in (
        (ROOT / "private", PUBLISHER, PUBLISHER, 0o700),
        (ROOT / "reader", READER, READER, 0o700),
        (PUBLIC / "resolver", PUBLISHER, READ_GID, 0o2750),
        (PUBLIC / "controller", PUBLISHER, READ_GID, 0o2750),
    ):
        path.mkdir(mode=0o700)
        os.chown(path, uid, gid)
        path.chmod(mode)
    event_read, event_write = os.pipe()
    reply_read, reply_write = os.pipe()

    def execute():
        from harness.r06_native import PERSONAL, exercise

        os.close(event_read)
        os.close(reply_write)
        result = {"scope": {}, "cases": []}

        def observe(policy, case):
            with os.fdopen(os.dup(event_write), "w") as stream:
                stream.write(json.dumps({"policy": policy, "case": case}) + "\n")
                stream.flush()
            with os.fdopen(os.dup(reply_read)) as stream:
                assert json.loads(stream.readline())["passed"], (
                    "native_metadata_reader_failed"
                )

        inputs = {
            **data["inputs"],
            "keys": {
                name: SecretStr(value) for name, value in data["inputs"]["keys"].items()
            },
            "family_observer_key": SecretStr(data["inputs"]["family_observer_key"]),
        }
        try:
            with (
                httpx.Client(
                    base_url="http://127.0.0.1:4000", trust_env=False, timeout=30
                ) as client,
                httpx.Client(
                    base_url="http://" + inputs["names"][PERSONAL] + ":8000",
                    trust_env=False,
                    timeout=10,
                ) as observer,
            ):
                exercise(
                    client,
                    observer,
                    data["control"],
                    data["observer_headers"],
                    result,
                    data["run_id"],
                    lambda: None,
                    runtime=ROOT / "private",
                    inputs=inputs,
                    publication_root=PUBLIC,
                    publication_reader_gid=READ_GID,
                    publication_observer=observe,
                )
            result["actor_privileges"] = privilege_state()
            return result
        except Exception as error:
            frame = traceback.extract_tb(error.__traceback__)[-1]
            result["status"] = "failed"
            result["failure"] = {
                "code": getattr(error, "code", type(error).__name__),
                "location": f"{Path(frame.filename).name}:{frame.lineno}",
            }
            return result
        finally:
            os.close(event_write)

    actor = start_user(PUBLISHER, [READ_GID], execute)
    os.close(event_write)
    os.close(reply_read)
    observations = []
    with os.fdopen(event_read) as events, os.fdopen(reply_write, "w") as replies:
        for event in events:
            request = json.loads(event)
            reader = as_user(
                READER, [READ_GID], lambda: read_publications(request["policy"])
            )
            retired = request["case"].endswith(
                "removed-template-denied-and-unowned-key-preserved"
            )
            expected = (
                not reader["passed"] and reader["error"] == "association_target_invalid"
                if retired
                else reader["passed"]
            )
            unrelated = require(as_user(UNRELATED, [], no_read_access))
            custody = require(as_user(READER, [READ_GID], no_write_or_private_access))
            observations.append(
                {
                    "case": request["case"],
                    "reader": reader,
                    "expected_current_policy_denial": retired,
                    "unrelated_read_denied": unrelated,
                    "reader_write_and_custody_denied": custody,
                }
            )
            replies.write(
                json.dumps({"passed": expected and unrelated and custody}) + "\n"
            )
            replies.flush()
    native = collect(actor)
    passed = native["passed"] and native["result"].get("status") == "passed"
    return {
        "status": "passed" if passed else "failed",
        "native": native.get("result"),
        "error": None if passed else native.get("result", {}).get("failure", native),
        "metadata_observations": observations,
        "uids": {"native_driver": PUBLISHER, "reader": READER, "unrelated": UNRELATED},
        "reader_gid": READ_GID,
        "scope": "Existing combined R06 driver, not split N03 services or inference-hook coverage",
    }
