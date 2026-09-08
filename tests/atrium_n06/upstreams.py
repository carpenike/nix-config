"""Non-actuating TLS destinations and authenticated counters for isolated N06."""

import base64
import datetime
import json
import os
import secrets
import ssl
import struct
import subprocess
import sys
import threading
import tarfile
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def main():
    inputs = json.loads(sys.stdin.readline())
    root = Path("/run/atrium-n06-upstreams")
    root.mkdir(mode=0o700, exist_ok=True)
    os.umask(0o077)
    with tarfile.open("/opt/n06-tools.tar.gz") as archive:
        archive.extractall("/", filter="fully_trusted")
    for address in (inputs["media_address"], inputs["canary_address"]):
        subprocess.run(
            [inputs["ip"], "address", "add", address + "/32", "dev", "lo"], check=True
        )
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = datetime.datetime.now(datetime.timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Atrium isolated N06")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(hours=6))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.SubjectAlternativeName(
                [x509.DNSName(host) for host in inputs["hosts"]]
            ),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    (root / "certificate.pem").write_bytes(
        certificate.public_bytes(serialization.Encoding.PEM)
    )
    (root / "key.pem").write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )

    def chunk(kind, body):
        return (
            struct.pack("!I", len(body))
            + kind
            + body
            + struct.pack("!I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n" + chunk(
        b"IHDR", struct.pack("!IIBBBBB", 2, 2, 8, 6, 0, 0, 0)
    )
    png += chunk(b"IDAT", zlib.compress((b"\0" + b"\x44\x55\x66\xff" * 2) * 2)) + chunk(
        b"IEND", b""
    )
    encoded = base64.b64encode(png).decode()
    token = jwt.encode(
        {
            "sub": "synthetic-partiful-user",
            "iat": int(now.timestamp()),
            "exp": int(now.timestamp()) + 3600,
        },
        key,
        algorithm="RS256",
    )
    lock = threading.Lock()
    events = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, value, content_type="application/json"):
            body = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.handle_request()

        def do_POST(self):
            self.handle_request()

        def handle_request(self):
            path = urlsplit(self.path).path
            host = self.headers.get("Host", "").split(":")[0]
            if self.server.server_port == 8000:
                if not secrets.compare_digest(
                    self.headers.get("Authorization", ""),
                    "Bearer " + inputs["observer"],
                ):
                    self.reply(401, {})
                elif path == "/state":
                    with lock:
                        self.reply(200, {"events": events})
                elif path == "/ca":
                    self.reply(
                        200,
                        (root / "certificate.pem").read_bytes(),
                        "application/x-pem-file",
                    )
                else:
                    self.reply(404, {})
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length > 8 * 1024 * 1024:
                self.reply(413, {})
                return
            body = self.rfile.read(length) if length else b""
            credentials = inputs["credentials"]
            expected = {
                "api.openai.com": ("Authorization", "Bearer " + credentials["openai"]),
                "generativelanguage.googleapis.com": (
                    "x-goog-api-key",
                    credentials["gemini"],
                ),
                "openrouter.ai": (
                    "Authorization",
                    "Bearer " + credentials["openrouter"],
                ),
                "api.partiful.com": ("Authorization", "Bearer " + token),
                "plex.atrium.invalid": ("X-Plex-Token", credentials["plex"]),
            }.get(host)
            authorized = expected is None or secrets.compare_digest(
                self.headers.get(expected[0], ""), expected[1]
            )
            if host == "securetoken.googleapis.com":
                authorized = credentials["partiful-refresh"].encode() in body
            with lock:
                events.append(
                    {
                        "host": host,
                        "path": path,
                        "method": self.command,
                        "authorized": authorized,
                    }
                )
            if not authorized:
                self.reply(401, {"error": "fixture-credential-refused"})
                return
            if host == "litellm.atrium.invalid":
                with httpx.Client(
                    trust_env=False, timeout=30, follow_redirects=False
                ) as client:
                    response = client.request(
                        self.command,
                        inputs["gateway"] + path,
                        content=body,
                        headers={
                            k: v
                            for k, v in self.headers.items()
                            if k.lower()
                            in ("authorization", "content-type", "anthropic-version")
                        },
                    )
                self.reply(
                    response.status_code,
                    response.content,
                    response.headers.get("content-type", "application/json"),
                )
            elif host == "api.openai.com" and path.startswith("/v1/images/"):
                self.reply(200, {"data": [{"b64_json": encoded}]})
            elif host == "generativelanguage.googleapis.com":
                self.reply(
                    200,
                    {
                        "candidates": [
                            {
                                "finishReason": "STOP",
                                "content": {
                                    "parts": [
                                        {
                                            "inlineData": {
                                                "mimeType": "image/png",
                                                "data": encoded,
                                            }
                                        }
                                    ]
                                },
                            }
                        ]
                    },
                )
            elif host == "openrouter.ai":
                self.reply(
                    200,
                    {
                        "choices": [
                            {
                                "finish_reason": "stop",
                                "message": {
                                    "images": [
                                        {
                                            "image_url": {
                                                "url": "data:image/png;base64,"
                                                + encoded
                                            }
                                        }
                                    ]
                                },
                            }
                        ],
                        "usage": {"cost": 0},
                    },
                )
            elif host == "securetoken.googleapis.com":
                self.reply(
                    200,
                    {
                        "id_token": token,
                        "expires_in": "3600",
                        "refresh_token": credentials["partiful-refresh"],
                    },
                )
            elif host == "api.partiful.com":
                self.reply(
                    200,
                    {
                        "result": {
                            "data": {"comments": [], "media": [], "hostMessages": []}
                        }
                    },
                )
            elif host == "identity.atrium.invalid":
                self.reply(
                    200,
                    {
                        "issuer": "https://identity.atrium.invalid",
                        "authorization_endpoint": "https://identity.atrium.invalid/authorize",
                        "token_endpoint": "https://identity.atrium.invalid/token",
                        "jwks_uri": "https://identity.atrium.invalid/jwks",
                        "userinfo_endpoint": "https://identity.atrium.invalid/userinfo",
                        "response_types_supported": ["code"],
                        "subject_types_supported": ["public"],
                        "id_token_signing_alg_values_supported": ["RS256"],
                    },
                )
            elif host == "media.atrium.invalid":
                self.reply(200, png, "image/png")
            elif host == "plex.atrium.invalid":
                self.reply(
                    200, {"MediaContainer": {"machineIdentifier": "synthetic-plex"}}
                )
            else:
                self.reply(200, {"fixture": True, "non_actuating": True})

    control = ThreadingHTTPServer(("0.0.0.0", 8000), Handler)
    threading.Thread(target=control.serve_forever, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "certificate.pem", root / "key.pem")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
