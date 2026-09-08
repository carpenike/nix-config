"""Unprivileged client network worker; requests use real TLS and native credentials."""

import base64
import io
import json
import os
import socket
import ssl
import sys
import tarfile
import secrets
import hashlib
from urllib.parse import parse_qs, urlencode, urlsplit
from pathlib import Path
from zipfile import ZipFile

ROOT = Path("/run/atrium-n03-client")


def reply(value):
    print(json.dumps(value), flush=True)


def worker():
    sys.path.insert(0, str(ROOT / "python"))
    import httpx

    config = json.loads((ROOT / "client.json").read_text())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if sys.version_info >= (3, 13):
        context.verify_flags |= ssl.VERIFY_X509_STRICT | ssl.VERIFY_X509_PARTIAL_CHAIN
    context.load_verify_locations(cafile=str(ROOT / "front-ca.pem"))
    clients = {}
    status = {}
    for line in Path("/proc/self/status").read_text().splitlines():
        if line.startswith(("Cap", "NoNewPrivs")):
            name, value = line.split(":", 1)
            status[name] = value.strip()
    reply(
        {
            "ready": True,
            "uid": os.geteuid(),
            "namespace": os.readlink("/proc/self/ns/net"),
            "privileges": status,
        }
    )
    try:
        for line in sys.stdin:
            command = json.loads(line)
            action = command["action"]
            if action == "stop":
                return
            if action == "request":
                parsed = urlsplit(command["url"])
                origin = f"{parsed.scheme}://{parsed.netloc}"
                if origin not in clients:
                    clients[origin] = httpx.Client(
                        verify=context, trust_env=False, timeout=15
                    )
                client = clients[origin]
                try:
                    response = client.request(
                        command["method"],
                        command["url"],
                        headers=command.get("headers"),
                        json=command.get("body"),
                    )
                    reply(
                        {
                            "status": response.status_code,
                            "body": response.text,
                            "headers": {
                                name: value
                                for name, value in response.headers.items()
                                if name
                                in (
                                    "content-type",
                                    "cache-control",
                                    "www-authenticate",
                                    "mcp-session-id",
                                )
                            },
                        }
                    )
                except httpx.HTTPError as error:
                    reply({"status": 0, "transport_error": type(error).__name__})
            elif action == "native-oauth":
                origin = config["endpoints"]["native"]
                if origin not in clients:
                    clients[origin] = httpx.Client(
                        verify=context, trust_env=False, timeout=15
                    )
                native = clients[origin]
                if command["operation"] == "refresh":
                    response = native.post(
                        origin + "/oauth/token",
                        data={
                            "grant_type": "refresh_token",
                            "client_id": command["client_id"],
                            "refresh_token": command["refresh_token"],
                            **(
                                {"scope": command["scope"]}
                                if "scope" in command
                                else {}
                            ),
                        },
                    )
                    reply({"status": response.status_code, "body": response.text})
                    continue
                registration = native.post(
                    origin + "/oauth/register",
                    json={
                        "redirect_uris": ["https://claude.ai/n03-fixture"],
                        "token_endpoint_auth_method": "none",
                    },
                )
                if registration.status_code != 201:
                    reply({"status": registration.status_code, "phase": "registration"})
                    continue
                client_id = registration.json()["client_id"]
                verifier = secrets.token_urlsafe(48)
                challenge = (
                    base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                    .decode()
                    .rstrip("=")
                )
                authorization = native.get(
                    origin + "/oauth/authorize",
                    params={
                        "client_id": client_id,
                        "redirect_uri": "https://claude.ai/n03-fixture",
                        "response_type": "code",
                        "code_challenge": challenge,
                        "code_challenge_method": "S256",
                        "scope": command.get("scope", "fixture.read"),
                        **command.get("overrides", {}),
                    },
                )
                if authorization.status_code != 302:
                    reply({"status": authorization.status_code, "phase": "authorize"})
                    continue
                upstream = (
                    authorization.headers["location"]
                    + "&"
                    + urlencode(
                        {
                            "fixture_principal": command.get(
                                "principal", "fixture-child"
                            ),
                            "fixture_lifetime": command.get("lifetime", 900),
                        }
                    )
                )
                signed_in = native.get(upstream)
                if signed_in.status_code != 302:
                    reply({"status": signed_in.status_code, "phase": "identity"})
                    continue
                callback = native.get(signed_in.headers["location"])
                if callback.status_code != 302:
                    reply({"status": callback.status_code, "phase": "callback"})
                    continue
                code = parse_qs(urlsplit(callback.headers["location"]).query)["code"][0]
                response = native.post(
                    origin + "/oauth/token",
                    data={
                        "grant_type": "authorization_code",
                        "client_id": client_id,
                        "redirect_uri": "https://claude.ai/n03-fixture",
                        "code": code,
                        "code_verifier": verifier,
                    },
                )
                reply(
                    {
                        "status": response.status_code,
                        "body": response.text,
                        "client_id": client_id,
                    }
                )
            elif action == "connect":
                try:
                    with socket.create_connection(
                        (command["address"], command["port"]), timeout=2
                    ):
                        reply({"connected": True})
                except OSError:
                    reply({"connected": False})
            elif action == "device":
                from pydantic import SecretStr
                from atrium_sidecar.client import DeviceClient
                from atrium_sidecar.config import Settings

                settings = Settings.model_validate_json(
                    json.dumps(
                        {
                            "enabled": True,
                            "state_directory": str(ROOT / "device-state"),
                            "device_id": "ryan-mac-fixture",
                            "principal": "ryan",
                            "resolver_url": config["endpoints"]["resolver"],
                            "registration_url": f"https://{config['names']['registration']}:{config['registrationPort']}",
                            "server_ca_path": str(ROOT / "front-ca.pem"),
                            "device_ca_path": str(ROOT / "device-ca.pem"),
                            "rsa_bits": 2048,
                            "local_available": [],
                            "registration_interval_seconds": 60,
                        }
                    )
                )
                client = DeviceClient(settings)
                try:
                    if command["operation"] == "initialize":
                        client.store.initialize()
                        reply({"completed": True})
                    elif command["operation"] == "proof":
                        from atrium_profiles.device import sign_device_challenge
                        from atrium_sidecar.state import private_key

                        challenge = command["challenge"]
                        with client.store.locked():
                            state = client.store.load()
                        slot = state.active
                        reply(
                            {
                                "ver": 1,
                                "nonce": challenge["nonce"],
                                "principal": challenge["principal"],
                                "purpose": challenge["purpose"],
                                "instance_ids": challenge["instance_ids"],
                                "device_id": settings.device_id,
                                "certificate_sha256": slot.certificate_sha256,
                                "signature": sign_device_challenge(
                                    challenge["nonce"],
                                    challenge["principal"],
                                    challenge["purpose"],
                                    private_key(slot),
                                ),
                            }
                        )
                    elif command["operation"] == "enroll":
                        client.enroll(SecretStr(command["authorization"]))
                        reply({"completed": True})
                    else:
                        reply({"completed": True, "registration": client.register()})
                except Exception as error:
                    reply(
                        {
                            "completed": False,
                            "error": getattr(error, "code", type(error).__name__),
                        }
                    )
            else:
                reply({"error": "unknown_client_action"})
    finally:
        for client in clients.values():
            client.close()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        worker()
        return
    import subprocess

    config = json.loads(sys.stdin.readline())
    ROOT.mkdir(mode=0o700, exist_ok=True)
    with tarfile.open("/opt/n03-tools.tar.gz") as archive:
        if any(
            not member.name.startswith("nix/store/") or ".." in Path(member.name).parts
            for member in archive
        ):
            raise ValueError("tool_archive_path_refused")
        archive.extractall("/", filter="fully_trusted")
    with ZipFile(io.BytesIO(base64.b64decode(config["python"]))) as archive:
        archive.extractall(ROOT / "python")
    subprocess.run(
        [
            config["tools"]["ip"],
            "route",
            "add",
            config["frontAddress"] + "/32",
            "via",
            config["foundationAddress"],
        ],
        check=True,
        capture_output=True,
    )
    (ROOT / "front-ca.pem").write_text(config["public"]["front-ca"])
    (ROOT / "device-ca.pem").write_text(config["public"]["device-ca"])
    (ROOT / "client.json").write_text(json.dumps(config["fixture"]))
    (ROOT / "client.py").write_text(config["source"])
    for path in [ROOT, *ROOT.rglob("*")]:
        if not path.is_symlink():
            os.chown(path, config["uid"], config["uid"])
    for name in ("front-ca.pem", "device-ca.pem", "client.json"):
        (ROOT / name).chmod(0o600)
    os.environ["PYTHONPATH"] = str(ROOT / "python")
    os.execv(
        config["tools"]["setpriv"],
        [
            config["tools"]["setpriv"],
            "--reuid",
            str(config["uid"]),
            "--regid",
            str(config["uid"]),
            "--clear-groups",
            "--bounding-set=-all",
            "--inh-caps=-all",
            "--ambient-caps=-all",
            "--no-new-privs",
            sys.executable,
            "-B",
            str(ROOT / "client.py"),
            "worker",
        ],
    )


if __name__ == "__main__":
    main()
