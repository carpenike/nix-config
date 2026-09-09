"""Synthetic identity/provider data behind real foundation transports."""

import json
import base64
import hashlib
import hmac
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

import jwt

ROOT = Path("/run/atrium-n03")


def main():
    fixture = json.loads((ROOT / "fixture.json").read_text())
    keys = json.loads((ROOT / "identity-jwks.json").read_text())
    state = Path("/var/lib/atrium-n03-fixture")
    state.mkdir(mode=0o700, exist_ok=True)
    counts = {"read": 0}
    credential_directory = Path("/run/credentials/atrium-n03-identity.service")
    identity_key = (credential_directory / "identity-key").read_bytes()
    native_client = json.loads(
        (credential_directory / "native-oidc-client").read_text()
    )
    codes = {}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            parsed = urlsplit(self.path)
            if parsed.path == "/authorize":
                query = parse_qs(parsed.query)
                required = (
                    "client_id",
                    "redirect_uri",
                    "state",
                    "nonce",
                    "response_type",
                    "code_challenge",
                    "code_challenge_method",
                )
                if any(len(query.get(name, [])) != 1 for name in required):
                    self.send_error(400)
                    return
                if (
                    query["client_id"][0] != native_client["client_id"]
                    or query["redirect_uri"][0] != native_client["redirect_uri"]
                    or query["response_type"][0] != "code"
                    or query["code_challenge_method"][0] != "S256"
                ):
                    self.send_error(400)
                    return
                principal = query.get("fixture_principal", ["fixture-child"])[0]
                record = fixture["generated"]["resolver"]["principals"].get(principal)
                try:
                    lifetime = int(query.get("fixture_lifetime", ["900"])[0])
                except ValueError:
                    lifetime = 0
                if (
                    record is None
                    or record["kind"] != "human"
                    or not 5 <= lifetime <= 900
                ):
                    self.send_error(400)
                    return
                now = int(time.time())
                code = secrets.token_urlsafe(32)
                with lock:
                    for expired in [
                        name
                        for name, value in codes.items()
                        if value["expires_at"] <= now
                    ]:
                        del codes[expired]
                    if len(codes) >= 64:
                        self.send_error(503)
                        return
                    codes[hashlib.sha256(code.encode()).hexdigest()] = {
                        "subject": record["bindings"][0]["subject"],
                        "groups": record["groups"],
                        "nonce": query["nonce"][0],
                        "challenge": query["code_challenge"][0],
                        "issued_at": now,
                        "expires_at": now + lifetime,
                    }
                self.send_response(302)
                self.send_header(
                    "Location",
                    native_client["redirect_uri"]
                    + "?"
                    + urlencode({"code": code, "state": query["state"][0]}),
                )
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/.well-known/jwks.json":
                body = keys
            elif self.path in (
                "/.well-known/openid-configuration",
                "/.well-known/oauth-authorization-server",
            ):
                origin = fixture["endpoints"]["identity"]
                body = {
                    "issuer": origin,
                    "jwks_uri": origin + "/.well-known/jwks.json",
                    "authorization_endpoint": origin + "/authorize",
                    "token_endpoint": origin + "/token",
                    "userinfo_endpoint": origin + "/userinfo",
                    "response_types_supported": ["code"],
                    "subject_types_supported": ["public"],
                    "id_token_signing_alg_values_supported": ["RS256"],
                }
            elif self.path == "/api/v1/endpoints/statuses":
                counts["read"] += 1
                target = state / "counts.json"
                descriptor = os.open(
                    target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
                )
                with os.fdopen(descriptor, "w") as stream:
                    json.dump(counts, stream)
                body = [
                    {
                        "group": "synthetic",
                        "name": "non-actuating",
                        "key": "fixture",
                        "results": [{"success": True}],
                    }
                ]
            elif self.path == "/healthz":
                body = {"status": "ok"}
            else:
                self.send_response(404)
                self.end_headers()
                return
            encoded = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_POST(self):
            if self.path != "/token":
                self.send_error(404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8192:
                    raise ValueError("bounded_form_required")
                form = parse_qs(self.rfile.read(length).decode("ascii"))
                required = (
                    "grant_type",
                    "client_id",
                    "client_secret",
                    "redirect_uri",
                    "code",
                    "code_verifier",
                )
                if any(len(form.get(name, [])) != 1 for name in required):
                    raise ValueError("invalid_form")
                if (
                    form["grant_type"][0] != "authorization_code"
                    or form["client_id"][0] != native_client["client_id"]
                    or form["redirect_uri"][0] != native_client["redirect_uri"]
                    or not hmac.compare_digest(
                        form["client_secret"][0], native_client["client_secret"]
                    )
                ):
                    raise ValueError("invalid_client")
                with lock:
                    pending = codes.pop(
                        hashlib.sha256(form["code"][0].encode()).hexdigest(), None
                    )
                challenge = (
                    base64.urlsafe_b64encode(
                        hashlib.sha256(
                            form["code_verifier"][0].encode("ascii")
                        ).digest()
                    )
                    .decode()
                    .rstrip("=")
                )
                if (
                    pending is None
                    or pending["expires_at"] <= int(time.time())
                    or not hmac.compare_digest(challenge, pending["challenge"])
                ):
                    raise ValueError("invalid_code")
                token = jwt.encode(
                    {
                        "iss": fixture["endpoints"]["identity"],
                        "aud": native_client["client_id"],
                        "sub": pending["subject"],
                        "email": "same-label@synthetic.invalid",
                        "nonce": pending["nonce"],
                        "iat": pending["issued_at"],
                        "exp": pending["expires_at"],
                        "groups": pending["groups"],
                    },
                    identity_key,
                    algorithm="RS256",
                    headers={"kid": "n03-identity"},
                )
            except (ValueError, UnicodeError):
                self.send_error(400)
                return
            encoded = json.dumps({"id_token": token}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    for host, port in (("127.0.0.4", 19100), ("127.0.0.5", 19101)):
        server = ThreadingHTTPServer((host, port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
