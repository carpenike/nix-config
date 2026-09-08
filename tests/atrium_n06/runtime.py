"""Invocation-owned namespace bootstrap with real N04 publication and Node helpers."""

import copy
import hashlib
import json
import os
import select
import subprocess
import sys
import tarfile
import time
from pathlib import Path

import httpx

ROOT = Path("/run/atrium-n06")
UID = 11001


def main():
    data = json.loads(sys.stdin.readline())
    os.umask(0o077)
    ROOT.mkdir(mode=0o755, exist_ok=True)
    ROOT.chmod(0o755)
    with tarfile.open("/opt/n06-tools.tar.gz") as archive:
        if not all(
            member.name.startswith("nix/store/") and ".." not in Path(member.name).parts
            for member in archive.getmembers()
        ):
            raise RuntimeError("tool_closure_paths_refused")
        archive.extractall("/", filter="fully_trusted")
    for path in (Path("/nix"), Path("/nix/store")):
        path.chmod(0o755)
    runtime = ROOT / "runtime"
    runtime.mkdir(mode=0o755)
    runtime.chmod(0o755)
    with tarfile.open("/opt/whiskey.tar.gz") as archive:
        archive.extractall(runtime, filter="fully_trusted")
    with tarfile.open("/opt/sqlite.tar.gz") as archive:
        archive.extractall(
            runtime / "node_modules/better-sqlite3", filter="fully_trusted"
        )
    for directory in ("providers", "input", "inventory"):
        (ROOT / directory).mkdir(mode=0o700)
    for directory in ("credentials", "delivery"):
        path = ROOT / directory
        path.mkdir(mode=0o750)
        path.chmod(0o750)
        os.chown(path, 0, UID)
    for directory in ("acks", "data"):
        path = ROOT / directory
        path.mkdir(mode=0o700)
        os.chown(path, UID, UID)
    for name, value in data.pop("sources").items():
        path = ROOT / "python" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
    sys.path.insert(0, str(ROOT / "python"))
    from atrium_litellm.associations import ProtectedSnapshotSource
    from atrium_litellm.controller import Controller
    from atrium_litellm.desired import Desired
    from atrium_litellm.files import atomic_json
    from atrium_litellm.ledger import Ledger
    from atrium_litellm.native import Native
    from egress import render

    for name, value in data.pop("provider_keys").items():
        (ROOT / "providers" / name).write_text(value)
    credentials = data.pop("credentials")
    for name, value in credentials.items():
        path = ROOT / "credentials" / name
        path.write_text(value)
        path.chmod(0o640)
        os.chown(path, 0, UID)
    partiful = ROOT / "credentials/partiful.json"
    partiful.write_text(
        json.dumps(
            {
                "refreshToken": credentials["partiful-refresh"],
                "firebaseApiKey": credentials["partiful-api"],
            }
        )
    )
    partiful.chmod(0o640)
    os.chown(partiful, 0, UID)
    features = ROOT / "credentials/features.json"
    features.write_text(json.dumps(data.pop("feature_inputs")))
    features.chmod(0o640)
    os.chown(features, 0, UID)
    (ROOT / "ca.pem").write_text(data["ca"])
    (ROOT / "ca.pem").chmod(0o644)
    (ROOT / "consumer.mjs").write_text(data["consumer"])
    (ROOT / "consumer.mjs").chmod(0o644)
    (ROOT / "feature_consumer.mjs").write_text(data["feature_consumer"])
    (ROOT / "feature_consumer.mjs").chmod(0o644)
    for path in runtime.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or os.access(path, os.X_OK) else 0o644)
    ip = data["ip"]
    for address in (data["media_address"], data["canary_address"]):
        subprocess.run(
            [ip, "route", "add", address + "/32", "via", data["upstream_address"]],
            check=True,
        )
    namespace = os.readlink("/proc/self/ns/net")
    policy_path, bindings_path = ROOT / "policy.json", ROOT / "bindings.json"
    policy_path.write_text(json.dumps(data["policy"]))
    bindings_path.write_text(json.dumps(data["bindings"]))
    expected_rules = render(data["policy"], data["bindings"])
    applied = subprocess.run(
        [
            sys.executable,
            str(ROOT / "python/egress.py"),
            "--policy",
            str(policy_path),
            "--bindings",
            str(bindings_path),
            "--expected-netns",
            namespace,
            "--nft",
            data["nft"],
        ],
        text=True,
        capture_output=True,
        check=True,
    )
    installation = json.loads(applied.stdout)
    installation["rules_sha256"] = hashlib.sha256(expected_rules.encode()).hexdigest()
    desired = Desired.parse(data["desired"])
    ledger = Ledger(
        ROOT / "inventory", data["installation"], "https://litellm.atrium.invalid"
    )
    ledger.initialize()
    source = ProtectedSnapshotSource(
        ROOT / "input/associations.json",
        data["installation"],
        "https://litellm.atrium.invalid",
        0,
    )
    operations = []
    native = Native(data["gateway"], data.pop("management_key"), operations=operations)
    transports = {
        name: {
            "api_base": "http://"
            + (
                "personal.models.atrium.invalid"
                if value["domain"] == "personal:ryan"
                else "family.models.atrium.invalid"
            )
            + ":8000/v1"
        }
        for name, value in desired.document["model_backends"].items()
    }
    controller = Controller(
        desired,
        ledger,
        native,
        source,
        transports,
        service_delivery={
            "whiskey-service": {
                "ack_path": str(ROOT / "acks/key.json"),
                "consumer_uid": UID,
                "consumer_gid": UID,
                "ack_timeout_seconds": 30,
            }
        },
    )
    model_config = {
        "schema_version": 1,
        "installation": data["installation"],
        "issuer": "https://litellm.atrium.invalid",
        "model": "cc.personal.ryan.text",
        "template_id": "whiskey-service",
        "key_path": str(ROOT / "delivery/key.json"),
        "key_owner_uid": 0,
        "acknowledgement_path": str(ROOT / "acks/key.json"),
        "isolated_harness": True,
    }
    (ROOT / "consumer.json").write_text(json.dumps(model_config))
    (ROOT / "consumer.json").chmod(0o644)
    environment = {
        "PATH": "/usr/bin:/bin",
        "NODE_ENV": "test",
        "HOME": str(ROOT / "data"),
        "DATA_DIR": str(ROOT / "data"),
        "NODE_EXTRA_CA_CERTS": str(ROOT / "ca.pem"),
        "WWW_ATRIUM_MODEL_CONFIG": str(ROOT / "consumer.json"),
        "OPENAI_API_KEY": credentials["openai"],
        "GEMINI_API_KEY": credentials["gemini"],
        "OPENROUTER_API_KEY": credentials["openrouter"],
        "WWW_OIDC_ISSUER": "https://identity.atrium.invalid",
        "WWW_OIDC_CLIENT_ID": "whiskey-fixture",
        "WWW_OIDC_REDIRECT_URI": "https://whiskey.atrium.invalid/callback",
        "PLEX_BASE_URL": "https://plex.atrium.invalid",
        "PLEX_TOKEN": credentials["plex"],
        "WWW_PUBLIC_BASE_ORIGIN": "https://whiskey.atrium.invalid",
        "PARTIFUL_CALENDAR_URL": "https://calendar.atrium.invalid/calendar.ics?token="
        + credentials["calendar"],
        "PARTIFUL_TIMEZONE": "UTC",
        "WWW_EXTERNAL_AS_ISSUER": "https://identity.atrium.invalid",
        "WWW_EXTERNAL_AS_RESOURCE": "https://whiskey.atrium.invalid/api/mcp",
        "WWW_EXTERNAL_AS_REQUIRED_SCOPE": "n06-read",
        "WWW_POCKETID_API_URL": "https://identity.atrium.invalid/api",
        "WWW_POCKETID_API_KEY": credentials["pocketid-admin"],
        "COOKLANG_BASE_URL": "https://cooklang.atrium.invalid",
        "WWW_MAILGUN_API_BASE": "https://mail.atrium.invalid",
        "WWW_MAILGUN_API_KEY": credentials["mailgun"],
        "WWW_MAILGUN_DOMAIN": "fixture.atrium.invalid",
        "WWW_MAIL_FROM": "N06 Fixture <sender@fixture.atrium.invalid>",
        "WWW_VAPID_PUBLIC_KEY": credentials["vapid-public"],
        "WWW_VAPID_PRIVATE_KEY": credentials["vapid-private"],
        "WWW_VAPID_SUBJECT": "mailto:fixture@example.invalid",
        "ATRIUM_N06_NFT": data["nft"],
    }
    consumer = subprocess.Popen(
        [
            data["setpriv"],
            "--reuid",
            str(UID),
            "--regid",
            str(UID),
            "--clear-groups",
            "--bounding-set=-all",
            "--inh-caps=-all",
            "--ambient-caps=-all",
            "--no-new-privs",
            "/usr/bin/node",
            str(ROOT / "consumer.mjs"),
        ],
        cwd=ROOT,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    def receive():
        if not select.select([consumer.stdout], [], [], 45)[0]:
            raise RuntimeError("consumer_response_timeout")
        value = consumer.stdout.readline()
        if not value:
            raise RuntimeError("consumer_exited")
        return json.loads(value)

    def reply(value):
        print(json.dumps(value), flush=True)

    reply({"ready": True, "consumer": receive(), "egress": installation})
    generation = 0
    backup = None
    try:
        for line in sys.stdin:
            request = json.loads(line)
            action = request["action"]
            if action == "stop":
                break
            try:
                if action in ("rotate", "reject-foreign-backend"):
                    generation += 1
                    now = int(time.time())
                    atomic_json(
                        source.path,
                        {
                            "schema_version": 1,
                            "kind": "atrium.litellm-associations",
                            "installation": data["installation"],
                            "issuer": "https://litellm.atrium.invalid",
                            "generation": generation,
                            "generated_at": now,
                            "expires_at": now + 300,
                            "associations": [],
                        },
                    )
                    if action == "reject-foreign-backend":
                        foreign = copy.deepcopy(desired.document)
                        foreign["model_backends"]["personal-text"]["domain"] = (
                            "family:holt"
                        )
                        Desired.parse(foreign)
                        raise RuntimeError("foreign_backend_accepted")
                    offset = len(operations)
                    report = controller.run()
                    reply(
                        {
                            "ok": True,
                            "rotation": report["service_rotation"],
                            "operations": operations[offset:],
                        }
                    )
                elif action == "hide-key":
                    backup = (ROOT / "delivery/key.json").read_bytes()
                    (ROOT / "delivery/key.json").unlink()
                    reply({"hidden": True})
                elif action == "restore-key":
                    atomic_json(
                        ROOT / "delivery/key.json",
                        json.loads(backup),
                        secret=True,
                        mode=0o640,
                        group=UID,
                    )
                    reply({"restored": True})
                elif action == "root-probe":
                    with httpx.Client(
                        trust_env=False, verify=str(ROOT / "ca.pem"), timeout=5
                    ) as client:
                        response = client.get(request["url"])
                        reply({"status": response.status_code})
                elif action == "rules":
                    rules = subprocess.run(
                        [data["nft"], "-j", "list", "table", "inet", "atrium_whiskey"],
                        capture_output=True,
                        text=True,
                        check=True,
                    )
                    reply({"rules": json.loads(rules.stdout)})
                else:
                    consumer.stdin.write(json.dumps(request) + "\n")
                    consumer.stdin.flush()
                    reply(receive())
            except Exception as error:  # noqa: BLE001 - never export native exception details
                reply(
                    {"ok": False, "code": getattr(error, "code", type(error).__name__)}
                )
    finally:
        if consumer.poll() is None:
            consumer.stdin.write('{"action":"stop"}\n')
            consumer.stdin.flush()
            consumer.stdin.close()
            consumer.wait(timeout=10)


if __name__ == "__main__":
    main()
