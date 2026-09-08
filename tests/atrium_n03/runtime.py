"""Invocation-owned foundation supervisor; service logic remains in accepted packages."""

import base64
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import traceback
from pathlib import Path
from zipfile import ZipFile
import io

ROOT = Path("/run/atrium-n03")


def reply(value):
    print(json.dumps(value), flush=True)


def start(uid, command, environment, tools):
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": "/run/atrium-n03",
        "PYTHONDONTWRITEBYTECODE": "1",
        "LITELLM_LOCAL_MODEL_COST_MAP": "True",
        "LITELLM_TELEMETRY": "False",
        "DO_NOT_TRACK": "1",
        **environment,
    }
    return subprocess.Popen(
        [
            tools["setpriv"],
            "--reuid",
            str(uid),
            "--regid",
            str(uid),
            "--clear-groups",
            "--bounding-set=-all",
            "--inh-caps=-all",
            "--ambient-caps=-all",
            "--no-new-privs",
            *command,
        ],
        env=env,
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def stop(processes):
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
    for process in reversed(processes):
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stderr.close()


def foundation(data):
    sys.path[:0] = [
        str(ROOT / "resolver-python"),
        str(ROOT / "native-python"),
        str(ROOT / "fixture"),
    ]
    from prepare import provision
    import jwt
    import ssl
    import httpx

    f, tools = data["fixture"], data["tools"]
    subprocess.run(
        [tools["ip"], "address", "add", f["frontAddress"] + "/32", "dev", "lo"],
        check=True,
        capture_output=True,
    )
    for name in ("whiskey",):
        with tarfile.open("/opt/n03-" + name + ".tar.gz") as archive:
            archive.extractall(ROOT / name, filter="data")
    with tarfile.open("/opt/n03-sqlite.tar.gz") as archive:
        archive.extractall(ROOT / "whiskey/node_modules/better-sqlite3", filter="data")
    config = provision(f)
    (ROOT / "Caddyfile").write_text(data["caddy"])
    (ROOT / "Caddyfile").chmod(0o644)
    roles = f["ids"]
    resolver_uid = roles["atrium-resolver-fixture"]["uid"]
    native_uid = roles["atrium-mcp-fixture"]["uid"]
    consumer_uid = roles["atrium-consumer-fixture"]["uid"]
    processes = []
    roles_by_pid = {}
    fault_active = False
    policy_stopped = False
    native_process = None
    policy_process = None

    def launch(role, uid, command, environment):
        process = start(uid, command, environment, tools)
        processes.append(process)
        roles_by_pid[process.pid] = role
        return process

    def running():
        for process in processes:
            if process.poll() is not None:
                output = process.stderr.read().decode(errors="replace")
                # Expose only a fixed final exception class, never configuration or HTTP payloads.
                lines = [
                    line
                    for line in output.splitlines()
                    if line.startswith(
                        (
                            "ModuleNotFoundError:",
                            "ValueError:",
                            "PermissionError:",
                            "Error:",
                        )
                    )
                ]
                locations = re.findall(r'File "([^"]+)", line ([0-9]+)', output)
                return {
                    "ready": False,
                    "code": "service_exited",
                    "role": roles_by_pid[process.pid],
                    "exit": process.returncode,
                    "diagnostic_kind": lines[-1].split(":", 1)[0]
                    if lines
                    else "unavailable",
                    "location": {
                        "file": Path(locations[-1][0]).name,
                        "line": int(locations[-1][1]),
                    }
                    if locations
                    else None,
                    "failure_tags": [
                        name
                        for name, text in {
                            "permission": "permission denied",
                            "missing_file": "no such file",
                            "address": "cannot assign requested address",
                            "configuration": "loading initial config",
                            "native_configuration": "resolver_configuration_or_state_rejected",
                        }.items()
                        if text in output.lower()
                    ],
                }
        return None

    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.load_verify_locations(cadata=config["public"]["front-ca"])
    native_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    native_tls.load_verify_locations(cadata=config["native_ca"])
    try:
        launch(
            "fixture",
            roles["atrium-identity-fixture"]["uid"],
            [sys.executable, "-B", str(ROOT / "fixture/fixture_services.py")],
            {},
        )
        launch(
            "caddy",
            roles["atrium-caddy-fixture"]["uid"],
            [
                tools["caddy"],
                "run",
                "--config",
                str(ROOT / "Caddyfile"),
                "--adapter",
                "caddyfile",
            ],
            {
                "XDG_DATA_HOME": "/var/lib/caddy",
                "XDG_CONFIG_HOME": "/var/lib/caddy",
            },
        )
        resolver_env = {
            "PYTHONPATH": str(ROOT / "resolver-python"),
            "NIX_SSL_CERT_FILE": "/run/credentials/atrium-resolver.service/front-ca",
        }
        launch(
            "resolver",
            resolver_uid,
            [
                sys.executable,
                "-B",
                "-m",
                "atrium_resolver.cli",
                "--config",
                "/etc/atrium/n03/resolver.json",
                "serve",
                "--port",
                "18765",
            ],
            resolver_env,
        )
        launch(
            "registration",
            resolver_uid,
            [
                sys.executable,
                "-B",
                "-m",
                "atrium_resolver.cli",
                "--config",
                "/etc/atrium/n03/registration.json",
                "serve-devices",
                "--port",
                "18766",
            ],
            resolver_env,
        )
        policy_command = [
            sys.executable,
            "-B",
            "-m",
            "atrium_resolver.cli",
            "--config",
            str(ROOT / "native-policy.json"),
            "serve-native-policy",
            "--port",
            str(f["nativePolicyPort"]),
        ]
        policy_process = launch(
            "native-policy", resolver_uid, policy_command, resolver_env
        )
        launch(
            "tcp-entry",
            roles["atrium-forwarder-fixture"]["uid"],
            [
                tools["socat"],
                f"TCP4-LISTEN:{f['registrationPort']},bind={f['frontAddress']},reuseaddr,fork",
                "TCP4:127.0.0.1:18766",
            ],
            {},
        )
        with httpx.Client(verify=tls, trust_env=False, timeout=2) as client:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if failure := running():
                    reply(failure)
                    return
                try:
                    if (
                        client.get(f["endpoints"]["resolver"] + "/healthz").status_code
                        == 200
                    ):
                        break
                except httpx.HTTPError:
                    pass
                time.sleep(0.2)
            else:
                raise ValueError("resolver_start_timeout")
        native_command = [sys.executable, "-B", str(ROOT / "fixture/native_service.py")]
        native_environment = {
            **config["native_environment"],
            "PYTHONPATH": str(ROOT / "native-python"),
            "NIX_SSL_CERT_FILE": "/run/credentials/homelab-mcp.service/front-ca",
        }
        native_process = launch(
            "native",
            native_uid,
            native_command,
            native_environment,
        )
        # The live W03 key path remains empty/closed pending the documented producer interface.
        delivery = ROOT / "delivery"
        delivery.mkdir(mode=0o750)
        os.chown(delivery, roles["atrium-reconciler-fixture"]["uid"], consumer_uid)
        ack = ROOT / "acknowledgements/whiskey"
        ack.mkdir(mode=0o750, parents=True)
        os.chown(ack, consumer_uid, roles["atrium-reconciler-fixture"]["uid"])
        (ROOT / "egress.json").write_text(json.dumps(f["egress"]))
        (ROOT / "bindings.json").write_text(
            json.dumps(
                {name: [f["frontAddress"]] for name in f["egress"]["destinations"]}
            )
        )
        subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "fixture/egress.py"),
                "--policy",
                str(ROOT / "egress.json"),
                "--bindings",
                str(ROOT / "bindings.json"),
                "--expected-netns",
                os.readlink("/proc/self/ns/net"),
                "--nft",
                tools["nft"],
            ],
            capture_output=True,
            check=True,
        )
        seed = start(
            consumer_uid,
            [tools["node"], str(ROOT / "fixture/whiskey_seed.mjs")],
            config["whiskey_environment"],
            tools,
        )
        try:
            if seed.wait(timeout=30) != 0:
                raise ValueError("whiskey_seed_failed")
        finally:
            seed.stderr.close()
        launch(
            "whiskey",
            consumer_uid,
            [tools["node"], str(ROOT / "whiskey/dist/server/index.js")],
            config["whiskey_environment"],
        )
        with (
            httpx.Client(verify=tls, trust_env=False, timeout=3) as client,
            httpx.Client(
                verify=native_tls,
                trust_env=False,
                timeout=3,
            ) as native_health,
        ):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if failure := running():
                    reply(failure)
                    return
                try:
                    if native_health.get(
                        f["endpoints"]["native"] + "/healthz"
                    ).status_code == 200 and client.get(
                        f["endpoints"]["whiskey"] + "/api/status"
                    ).status_code in (200, 401, 403):
                        break
                except httpx.HTTPError:
                    pass
                time.sleep(0.3)
            else:
                raise ValueError("native_start_timeout")

        def identity_token(principal, *, lifetime=1200, claims=None):
            row = f["generated"]["resolver"]["principals"][principal]
            now = int(time.time())
            return jwt.encode(
                {
                    "iss": f["endpoints"]["identity"],
                    "aud": "atrium-isolated-fixture",
                    "sub": row["bindings"][0]["subject"],
                    "jti": __import__("secrets").token_hex(16),
                    "client_id": "n03-fixture",
                    "iat": now,
                    "exp": now + lifetime,
                    "groups": row["groups"],
                    **(claims or {}),
                },
                config["identity_key"],
                algorithm="RS256",
                headers={"typ": "at+jwt", "kid": "n03-identity"},
            )

        service_status = {}
        for process in processes:
            observed = {}
            for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                if line.startswith(("Uid:", "Gid:", "Cap", "NoNewPrivs")):
                    name, value = line.split(":", 1)
                    observed[name] = value.strip()
            service_status[roles_by_pid[process.pid]] = observed
        reply(
            {
                "ready": True,
                "namespace": os.readlink("/proc/self/ns/net"),
                "services": service_status,
                "public": config["public"],
                "native_policy": {
                    "endpoint": f["nativePolicyEndpoint"],
                    "uid": resolver_uid,
                    "state_shared_only_with_resolver": True,
                    "client_certificate_sha256": config["policy_fingerprint"],
                    "native_client_uid": native_uid,
                },
            }
        )
        for line in sys.stdin:
            command = json.loads(line)
            if command["action"] == "stop":
                return
            if command["action"] == "identity":
                reply(
                    {
                        "token": identity_token(
                            command["principal"],
                            lifetime=command.get("lifetime", 1200),
                            claims=command.get("claims"),
                        )
                    }
                )
            elif command["action"] == "effects":
                path = Path("/var/lib/atrium-n03-fixture/counts.json")
                resource = Path(f["state"]["native"]) / "resource-count.json"
                reply(
                    {
                        "read": json.loads(path.read_text())["read"]
                        if path.exists()
                        else 0,
                        "resource": json.loads(resource.read_text())
                        if resource.exists()
                        else 0,
                    }
                )
            elif command["action"] == "native-peer":
                from prepare import write

                prefix = "wrong-" if command["wrong"] else ""
                for name in ("native-client-cert", "native-client-key"):
                    path = Path("/run/credentials/atrium-resolver.service") / name
                    path.unlink()
                    write(
                        path,
                        config["native_client_material"][prefix + name],
                        resolver_uid,
                    )
                reply({"changed": True})
            elif command["action"] == "native-state":
                import sqlite3

                with sqlite3.connect(f["state"]["native"] + "/state.db") as database:
                    issued = database.execute(
                        "SELECT count(*) FROM native_issuance"
                    ).fetchone()[0]
                    public_access = database.execute(
                        "SELECT count(*) FROM public_native_access"
                    ).fetchone()[0]
                    refreshes = database.execute(
                        "SELECT count(*) FROM refresh_token"
                    ).fetchone()[0]
                with sqlite3.connect(
                    f["state"]["native"] + "/denial/denial.sqlite"
                ) as database:
                    alerts = database.execute(
                        "SELECT count(*) FROM freshness_alerts"
                    ).fetchone()[0]
                    snapshot = json.loads(
                        database.execute(
                            "SELECT document FROM snapshot WHERE singleton=1"
                        ).fetchone()[0]
                    )
                reply(
                    {
                        "issued": issued,
                        "public_access": public_access,
                        "refreshes": refreshes,
                        "alerts": alerts,
                        "generation": snapshot["generation"],
                    }
                )
            elif command["action"] == "policy-state":
                import sqlite3

                with sqlite3.connect(
                    f["state"]["resolver"] + "/resolver.sqlite3"
                ) as database:
                    counts = {
                        table: database.execute(
                            f"SELECT count(*) FROM {table}"
                        ).fetchone()[0]
                        for table in (
                            "native_policy_requests",
                            "credential_associations",
                            "group_assertions",
                        )
                    }
                    group_deadlines = [
                        row[0]
                        for row in database.execute(
                            "SELECT expires_at FROM group_assertions WHERE principal_id = ?",
                            (command.get("principal", "fixture-child"),),
                        )
                    ]
                reply({"counts": counts, "group_deadlines": group_deadlines})
            elif command["action"] == "policy-outage":
                if command["enabled"]:
                    if policy_stopped:
                        raise ValueError("policy_fault_already_owned")
                    stop([policy_process])
                    processes.remove(policy_process)
                    policy_stopped = True
                else:
                    if not policy_stopped:
                        raise ValueError("policy_fault_not_owned")
                    policy_process = launch(
                        "native-policy", resolver_uid, policy_command, resolver_env
                    )
                    policy_stopped = False
                reply({"changed": True})
            elif command["action"] == "policy-peer":
                from prepare import write

                stop([native_process])
                processes.remove(native_process)
                prefix = "wrong-" if command["wrong"] else ""
                for name in ("policy-client-cert", "policy-client-key"):
                    path = Path("/run/credentials/homelab-mcp.service") / name
                    path.unlink()
                    write(
                        path,
                        config["policy_client_material"][prefix + name],
                        native_uid,
                    )
                native_process = launch(
                    "native", native_uid, native_command, native_environment
                )
                with httpx.Client(
                    verify=native_tls, trust_env=False, timeout=2
                ) as native_health:
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        if failure := running():
                            reply(failure)
                            break
                        try:
                            if (
                                native_health.get(
                                    f["endpoints"]["native"] + "/healthz"
                                ).status_code
                                == 200
                            ):
                                reply({"changed": True})
                                break
                        except httpx.HTTPError:
                            pass
                        time.sleep(0.2)
                    else:
                        raise ValueError("native_start_timeout")
            elif command["action"] == "policy-probe":
                # Only adverse probes use this synthetic assertion. All permits use
                # actual native OAuth/current-access -> native policy transport.
                from copy import deepcopy
                from uuid import uuid4

                mode = command["mode"]
                current = int(time.time())
                body = {
                    "schema_version": 1,
                    "request_id": uuid4().hex,
                    "audience": f["nativePolicyEndpoint"],
                    "native_issuer": f["endpoints"]["native"],
                    "authority": "pocket-id-fixture",
                    "identity": {
                        "issuer": f["endpoints"]["identity"],
                        "subject": f["generated"]["resolver"]["principals"][
                            "fixture-child"
                        ]["bindings"][0]["subject"],
                    },
                    "resource": deepcopy(f["native"]["resource"]),
                    "scopes": ["fixture.read"],
                    "operation": "issue",
                    "verification": {
                        "kind": "refresh",
                        "credential_issuer": f["endpoints"]["native"],
                        "credential_id": "sha256:" + "0" * 64,
                        "observed_at": current,
                        "expires_at": current + 60,
                    },
                }
                if mode not in (
                    "missing-peer",
                    "wrong-peer",
                    "audience",
                    "authority",
                    "view",
                ):
                    raise ValueError("adverse_policy_probe_required")
                probe = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                probe.load_verify_locations(cadata=config["policy_ca"])
                if mode != "missing-peer":
                    prefix = "wrong-" if mode == "wrong-peer" else ""
                    # Load only already provisioned invocation-owned test material.
                    material = config["policy_client_material"]
                    for suffix in ("cert", "key"):
                        path = ROOT / ("policy-probe." + suffix)
                        path.unlink(missing_ok=True)
                        from prepare import write

                        write(path, material[prefix + "policy-client-" + suffix])
                    probe.load_cert_chain(
                        ROOT / "policy-probe.cert", ROOT / "policy-probe.key"
                    )
                if mode == "audience":
                    body["audience"] = f["endpoints"]["resolver"] + "/v1/native-policy"
                elif mode == "authority":
                    body["authority"] = "unregistered-authority"
                elif mode == "view":
                    body["resource"]["id"] = "unknown-view"
                try:
                    with httpx.Client(verify=probe, trust_env=False, timeout=5) as peer:
                        rejected = peer.post(
                            f["nativePolicyEndpoint"],
                            json=body,
                            headers={
                                "X-SSL-Client-Verify": "SUCCESS",
                                "X-Principal": "ryan",
                            },
                        )
                        reply({"status": rejected.status_code})
                except httpx.HTTPError as error:
                    reply({"status": 0, "transport_error": type(error).__name__})
                finally:
                    (ROOT / "policy-probe.cert").unlink(missing_ok=True)
                    (ROOT / "policy-probe.key").unlink(missing_ok=True)
            elif command["action"] == "observed-headers":
                reply(
                    json.loads(
                        (
                            Path(f["state"]["native"]) / "n03-observed-headers.json"
                        ).read_text()
                    )
                )
            elif command["action"] == "feed-outage":
                table = "atrium_n03_feed_fault"
                if command["enabled"]:
                    if fault_active:
                        raise ValueError("feed_fault_already_owned")
                    exists = subprocess.run(
                        [tools["nft"], "list", "table", "inet", table],
                        capture_output=True,
                    )
                    if exists.returncode == 0:
                        raise ValueError("foreign_feed_fault_table")
                    rule = (
                        f"table inet {table} {{\n chain output {{\n type filter hook output priority 10; policy accept;\n "
                        f"meta skuid {{ {native_uid}, {consumer_uid} }} ip daddr {f['frontAddress']} tcp dport {f['port']} "
                        "counter reject with icmpx type admin-prohibited\n }\n}\n"
                    )
                    applied = subprocess.run(
                        [tools["nft"], "-f", "-"],
                        input=rule,
                        text=True,
                        capture_output=True,
                    )
                    if applied.returncode:
                        reply(
                            {
                                "changed": False,
                                "code": "feed_fault_installation_failed",
                                "syntax_error": "syntax error"
                                in applied.stderr.lower(),
                            }
                        )
                        continue
                    fault_active = True
                else:
                    if not fault_active:
                        raise ValueError("feed_fault_not_owned")
                    subprocess.run(
                        [tools["nft"], "delete", "table", "inet", table],
                        capture_output=True,
                        check=True,
                    )
                    fault_active = False
                reply(
                    {
                        "changed": True,
                        "namespace": os.readlink("/proc/self/ns/net"),
                        "table": table,
                    }
                )
            else:
                reply({"error": "unknown_fixture_action"})
    finally:
        stop(processes)


def main():
    data = json.loads(sys.stdin.readline())
    ROOT.mkdir(mode=0o755, exist_ok=True)
    for name, contents in data["archives"].items():
        with ZipFile(io.BytesIO(base64.b64decode(contents))) as archive:
            archive.extractall(ROOT / name)
    with tarfile.open("/opt/n03-tools.tar.gz") as archive:
        for member in archive:
            if (
                not member.name.startswith("nix/store/")
                or ".." in Path(member.name).parts
            ):
                raise ValueError("tool_archive_path_refused")
        archive.extractall("/", filter="fully_trusted")
    probe = """
import json
try:
 import homelab_mcp.app
 print(json.dumps({"ready":True}))
except ModuleNotFoundError as error:
 print(json.dumps({"ready":False,"missing":error.name}))
"""
    env = os.environ | {
        "PYTHONPATH": str(ROOT / "native-python"),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    checked = subprocess.run(
        [sys.executable, "-B", "-c", probe], env=env, capture_output=True, text=True
    )
    imported = json.loads(checked.stdout)
    if imported.get("ready") and data.get("fixture") is not None:
        foundation(data)
        return
    reply(imported)
    for line in sys.stdin:
        command = json.loads(line)
        if command["action"] == "stop":
            return
        reply({"error": "bootstrap_only"})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        frame = traceback.extract_tb(error.__traceback__)[-1]
        known = {
            "resolver_start_timeout",
            "native_start_timeout",
            "whiskey_seed_failed",
            "tool_archive_path_refused",
        }
        reply(
            {
                "ready": False,
                "code": str(error) if str(error) in known else type(error).__name__,
                "file": Path(frame.filename).name,
                "line": frame.lineno,
            }
        )
        raise SystemExit(1) from None
