#!/usr/bin/env python3
"""Idempotent OpenProject bootstrap for the Grok bots (API v3, stdlib only).

Creates one OpenProject user per bot, one private project per bot plus a
shared project, and memberships (bot -> own project + shared project) with a
single project role. Re-running only fills in what is missing.

Auth: an admin API token (My account -> Access tokens -> API) passed via
OP_ADMIN_TOKEN_FILE (preferred) or OP_ADMIN_TOKEN. Never commit the token.

    OP_URL=http://127.0.0.1:8072 \\
    OP_ADMIN_TOKEN_FILE=/run/user/$UID/op-admin-token \\
    python3 hosts/forge/services/openproject/bootstrap.py --dry-run

API tokens for the bots cannot be created through API v3; mint them with
mint-api-tokens.sh afterwards. See docs/services/openproject.md.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
import string
import sys
import urllib.error
import urllib.parse
import urllib.request

BOTS = [
    # login, first name, last name, project identifier, project name
    (
        "bot-executive-assistant",
        "Executive",
        "Assistant",
        "bot-executive-assistant",
        "Executive Assistant",
    ),
    ("bot-social-planner", "Social", "Planner", "bot-social-planner", "Social Planner"),
    ("bot-finances", "Finances", "Bot", "bot-finances", "Finances"),
    (
        "bot-homelab-manager",
        "Homelab",
        "Manager",
        "bot-homelab-manager",
        "Homelab Manager",
    ),
    ("bot-grok", "Grok", "Bot", "bot-grok", "Grok Bot"),
]
SHARED_PROJECT = ("bots-shared", "Bots - Shared Queue")


class Api:
    def __init__(self, base: str, token: str, dry_run: bool) -> None:
        self.base = base.rstrip("/")
        cred = base64.b64encode(f"apikey:{token}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {cred}",
            "Content-Type": "application/json",
            "Accept": "application/hal+json",
        }
        self.dry_run = dry_run

    def request(
        self, method: str, path: str, body: dict | None = None
    ) -> tuple[int, dict]:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.base + path, data=data, method=method, headers=self.headers
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            payload = err.read()
            try:
                return err.code, json.loads(payload or b"{}")
            except json.JSONDecodeError:
                return err.code, {"message": payload.decode(errors="replace")}

    def get(self, path: str) -> tuple[int, dict]:
        return self.request("GET", path)

    def create(self, path: str, body: dict, what: str) -> dict:
        if self.dry_run:
            print(f"  [dry-run] would create {what}")
            return {"id": None, "_links": {"self": {"href": None}}}
        status, payload = self.request("POST", path, body)
        if status not in (200, 201):
            sys.exit(
                f"creating {what} failed ({status}): {payload.get('message', payload)}"
            )
        print(f"  created {what}")
        return payload


def filters(**conds: list[str]) -> str:
    spec = [{k: {"operator": "=", "values": v}} for k, v in conds.items()]
    return urllib.parse.quote(json.dumps(spec))


def random_password() -> str:
    # Satisfies OpenProject's default rules (lower, upper, digit, special).
    # Bots never log in with it; they authenticate with API tokens.
    alphabet = string.ascii_letters + string.digits
    core = "".join(secrets.choice(alphabet) for _ in range(28))
    return f"{core}aA1!"


def ensure_project(api: Api, identifier: str, name: str) -> str | None:
    status, payload = api.get(f"/api/v3/projects/{identifier}")
    if status == 200:
        print(f"  project {identifier} exists")
        return payload["_links"]["self"]["href"]
    if status != 404:
        sys.exit(
            f"looking up project {identifier} failed ({status}): {payload.get('message')}"
        )
    body = {"identifier": identifier, "name": name, "public": False}
    return api.create("/api/v3/projects", body, f"project {identifier}")["_links"][
        "self"
    ]["href"]


def ensure_user(
    api: Api, login: str, first: str, last: str, email_domain: str
) -> str | None:
    status, payload = api.get(f"/api/v3/users?filters={filters(login=[login])}")
    if status != 200:
        sys.exit(f"looking up user {login} failed ({status}): {payload.get('message')}")
    elements = payload.get("_embedded", {}).get("elements", [])
    if elements:
        print(f"  user {login} exists")
        return elements[0]["_links"]["self"]["href"]
    body = {
        "login": login,
        "email": f"{login}@{email_domain}",
        "firstName": first,
        "lastName": last,
        "admin": False,
        "status": "active",
        "language": "en",
        "password": random_password(),
    }
    return api.create("/api/v3/users", body, f"user {login}")["_links"]["self"]["href"]


def find_role(api: Api, role_name: str) -> str:
    status, payload = api.get("/api/v3/roles?pageSize=100")
    if status != 200:
        sys.exit(f"listing roles failed ({status}): {payload.get('message')}")
    for role in payload.get("_embedded", {}).get("elements", []):
        if role.get("name") == role_name:
            return role["_links"]["self"]["href"]
    sys.exit(
        f"role {role_name!r} not found; create it in Administration -> Users and permissions -> Roles"
    )


def ensure_membership(
    api: Api,
    project_href: str | None,
    user_href: str | None,
    role_href: str,
    label: str,
) -> None:
    if project_href is None or user_href is None:
        print(f"  [dry-run] would add membership {label}")
        return
    project_id = project_href.rsplit("/", 1)[-1]
    user_id = user_href.rsplit("/", 1)[-1]
    status, payload = api.get(
        f"/api/v3/memberships?filters={filters(project=[project_id], principal=[user_id])}"
    )
    if status != 200:
        sys.exit(
            f"looking up membership {label} failed ({status}): {payload.get('message')}"
        )
    if payload.get("_embedded", {}).get("elements"):
        print(f"  membership {label} exists")
        return
    body = {
        "_links": {
            "project": {"href": project_href},
            "principal": {"href": user_href},
            "roles": [{"href": role_href}],
        }
    }
    api.create("/api/v3/memberships", body, f"membership {label}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--url", default=os.environ.get("OP_URL", "http://127.0.0.1:8072")
    )
    parser.add_argument(
        "--role",
        default=os.environ.get("OP_BOT_ROLE", "Member"),
        help="project role for bots",
    )
    parser.add_argument(
        "--email-domain",
        default=os.environ.get("OP_BOT_EMAIL_DOMAIN", "bots.holthome.net"),
        help="placeholder mail domain for bot accounts (no mail is configured)",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    token_file = os.environ.get("OP_ADMIN_TOKEN_FILE")
    if token_file:
        with open(token_file, encoding="utf-8") as fh:
            token = fh.read().strip()
    else:
        token = os.environ.get("OP_ADMIN_TOKEN", "").strip()
    if not token:
        sys.exit("set OP_ADMIN_TOKEN_FILE (preferred) or OP_ADMIN_TOKEN")

    api = Api(args.url, token, args.dry_run)
    role_href = find_role(api, args.role)

    print("projects:")
    shared_href = ensure_project(api, *SHARED_PROJECT)
    project_hrefs = {
        ident: ensure_project(api, ident, name) for _, _, _, ident, name in BOTS
    }

    print("users and memberships:")
    for login, first, last, ident, _ in BOTS:
        user_href = ensure_user(api, login, first, last, args.email_domain)
        ensure_membership(
            api, project_hrefs[ident], user_href, role_href, f"{login} -> {ident}"
        )
        ensure_membership(
            api, shared_href, user_href, role_href, f"{login} -> {SHARED_PROJECT[0]}"
        )

    print("done. next: hosts/forge/services/openproject/mint-api-tokens.sh")


if __name__ == "__main__":
    main()
