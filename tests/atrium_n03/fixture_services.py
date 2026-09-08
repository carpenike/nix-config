"""Synthetic identity/provider data behind real foundation transports."""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path("/run/atrium-n03")


def main():
    fixture = json.loads((ROOT / "fixture.json").read_text())
    keys = json.loads((ROOT / "identity-jwks.json").read_text())
    state = Path("/var/lib/atrium-n03-fixture")
    state.mkdir(mode=0o700, exist_ok=True)
    counts = {"read": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
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

    for host, port in (("127.0.0.4", 19100), ("127.0.0.5", 19101)):
        server = ThreadingHTTPServer((host, port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
