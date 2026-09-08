"""The accepted native entrypoint, with only non-actuating provider inputs."""

import json
import os
from pathlib import Path

from homelab_mcp import app
from homelab_mcp.tools import finances_docs, gatus

STATE = Path("/var/lib/homelab-mcp")


class Documents:
    def __init__(self, *_args, **_kwargs):
        pass

    def read(self, name):
        if name not in finances_docs.DOCS:
            raise ValueError("unknown_fixture_document")
        path = STATE / "resource-count.json"
        count = json.loads(path.read_text()) if path.exists() else 0
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(count + 1, stream)
        return "Synthetic resource data", None


def providers(mcp, settings, _mint):
    gatus.register(mcp, settings)
    finances_docs.Repo = Documents
    finances_docs.register(mcp, settings)


class ObserveHeaders:
    def __init__(self, app):
        self.application = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and (
            scope.get("path", "").startswith("/cc/views/")
            or scope.get("path") == "/mcp"
        ):
            headers = {
                name.decode().lower(): value.decode()
                for name, value in scope.get("headers", [])
            }
            names = (
                "forwarded",
                "x-ssl-client-verify",
                "x-forwarded-client-cert",
                "x-client-cert",
                "x-forwarded-user",
                "x-remote-user",
                "x-auth-request-user",
                "x-principal",
                "x-admin",
            )
            value = {
                "identity_assertion_headers": [
                    name for name in names if name in headers
                ],
                "forwarded_for": headers.get("x-forwarded-for"),
                "forwarded_proto": headers.get("x-forwarded-proto"),
                "forwarded_host": headers.get("x-forwarded-host"),
                "upstream_host": headers.get("host"),
            }
            descriptor = os.open(
                STATE / "n03-observed-headers.json",
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                0o600,
            )
            with os.fdopen(descriptor, "w") as stream:
                json.dump(value, stream)
        await self.application(scope, receive, send)


if __name__ == "__main__":
    app.register_all = providers
    original = app.build_app

    def observed(settings):
        application = original(settings)
        application.add_middleware(ObserveHeaders)
        return application

    app.build_app = observed
    app.main()
