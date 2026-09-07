"""Isolated native fixture: real R07 service, R06/N04 producers, synthetic inputs."""

import hashlib
import json
import logging
import os
import secrets
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import jwt
import uvicorn
from cryptography.hazmat.primitives.asymmetric import rsa
from pydantic import SecretStr

from atrium_admission.models import Settings as AdmissionSettings
from atrium_admission.state import State as AdmissionState
from atrium_litellm.controller import Controller
from atrium_litellm.ledger import Ledger
from atrium_profiles.deny import DenyClaims
from atrium_profiles.runtime import atomic_private_write, private_directory
from atrium_resolver.app import create_app
from atrium_resolver.config import Authority, Bootstrap, Settings
from atrium_resolver.litellm_broker import ModelKeyMetadata
from atrium_resolver.litellm_config import LiteLLMSettings
from atrium_resolver.litellm_inventory import publish_associations
from atrium_resolver.litellm_native import NativeKeyClient
from atrium_resolver.native_revocation import NativeKeyRevoker
from atrium_resolver.policy import PolicyEngine, PolicySeed
from atrium_resolver.policy_schema import Budget, INFERENCE_ROUTES, PolicyDocument
from atrium_resolver.signing import SigningService, SigningSettings
from atrium_resolver.state import State

ROOT = Path("/run/atrium-n05")
ISSUER = "http://127.0.0.1:4000"


class Fixture:
    def __init__(self, inputs):
        self.control = inputs["fixture_control"]
        self.master = inputs["master"]
        self.identity_key = rsa.generate_private_key(
            public_exponent=65537, key_size=2048
        )
        self.jwk = json.loads(
            jwt.algorithms.RSAAlgorithm.to_jwk(self.identity_key.public_key())
        )
        self.jwk.update(kid="fixture-idp", alg="RS256", use="sig")
        self.policy = inputs["policy"]
        self.policy_path = ROOT / "policy.json"
        self.feed_mode = "live"
        self.feed_override = None
        self.feed_backup = None
        self.producer_backups = {}
        self.policy_backup = None
        self.keys = {}
        self.native_users = set()
        for record in self.policy["authorities"].values():
            record["jwks_uri"] = "http://127.0.0.1:9010/jwks"
        for template in self.policy["model_templates"].values():
            template["routes"] = sorted(INFERENCE_ROUTES)
        atomic_private_write(self.policy_path, json.dumps(self.policy).encode())
        self.control_file = ROOT / "native-control"
        self.revocation_file = ROOT / "revocation-control"
        atomic_private_write(self.control_file, self.master.encode())
        atomic_private_write(self.revocation_file, self.master.encode())
        self.native = NativeKeyClient(ISSUER, self.control_file)
        self.revocation = NativeKeyClient(ISSUER, self.revocation_file)
        self.state = State(ROOT / "resolver-state")
        authorities = tuple(
            Authority(
                id=name,
                **{key: record[key] for key in ("issuer", "audience", "jwks_uri")},
            )
            for name, record in self.policy["authorities"].items()
        )
        signing = SigningSettings(
            directory=ROOT / "signing", issuer="https://resolver.atrium.invalid"
        )
        self.signing = SigningService(signing)
        self.signing.keyring.initialize(now=int(time.time()) - 2000)
        self.settings = Settings(
            authorities=authorities,
            isolated_harness=True,
            state_directory=ROOT / "resolver-state",
            policy_path=self.policy_path,
            group_authority="fixture-pocket-id",
            signing=signing,
        )
        self.state.configure_authorities(authorities)
        enrollment = {
            "schema_version": 1,
            "principals": [
                {
                    "id": name,
                    "display_name": row["display_name"],
                    "kind": row["kind"],
                    "roles": row["roles"],
                }
                for name, row in self.policy["principals"].items()
                if row["status"] == "active"
            ],
            "identities": [
                {
                    "principal": name,
                    "authority": binding["authority"],
                    "subject": binding["subject"],
                }
                for name, row in self.policy["principals"].items()
                if row["status"] == "active"
                for binding in row["bindings"]
            ],
        }
        engine = PolicyEngine(self.settings, self.state)
        enrollment = Bootstrap.model_validate_json(json.dumps(enrollment))
        engine.validate_enrollment(enrollment)
        self.state.bootstrap(enrollment)
        seed = inputs["seed"]
        for row in seed["grants"]:
            if row["request"]["template_id"] in self.policy["model_templates"]:
                row["request"]["routes"] = sorted(INFERENCE_ROUTES)
        engine.seed_local(PolicySeed.model_validate_json(json.dumps(seed)))
        self.broker_settings = LiteLLMSettings(
            endpoint=ISSUER,
            installation="n05-fixture",
            runtime_directory=private_directory(ROOT / "producer-r06"),
            controller_key_file=self.control_file,
            controller_inventory_file=ROOT / "unused-bindings",
            controller_desired_state_path=ROOT / "unused-desired",
        )
        publish_associations(
            self.broker_settings.runtime_directory, self.state, self.broker_settings
        )
        self.ledger = Ledger(
            private_directory(ROOT / "producer-n04"), "n05-fixture", ISSUER
        )
        self.ledger.initialize()
        self.controller = Controller(None, self.ledger, None, None, {})
        self.publish_services()
        admission = AdmissionSettings.model_validate(
            {
                "schema_version": 1,
                "isolated": True,
                "installation": "n05-fixture",
                "issuer": ISSUER,
                "runtime_directory": ROOT / "admission-state",
                "policy_path": self.policy_path,
                "policy_publisher_uid": os.geteuid(),
                "producers": (
                    {
                        "id": "resolver",
                        "kind": "resolver",
                        "path": ROOT / "producer-r06/admission-associations.json",
                        "publisher_uid": os.geteuid(),
                    },
                    {
                        "id": "services",
                        "kind": "controller-service",
                        "path": ROOT / "producer-n04/service-associations.json",
                        "publisher_uid": os.geteuid(),
                    },
                ),
                "deny_issuer": signing.issuer,
                "deny_url": "http://127.0.0.1:9010/feed",
                "jwks_url": "http://127.0.0.1:8765/.well-known/jwks.json",
                "poll_seconds": 1,
                "fetch_timeout_seconds": 2,
            }
        )
        atomic_private_write(
            ROOT / "admission-settings.json", admission.model_dump_json().encode()
        )
        AdmissionState(admission).initialize()
        self.app = create_app(
            self.settings, native_revoker=NativeKeyRevoker(self.revocation)
        )
        self.server = uvicorn.Server(
            uvicorn.Config(
                self.app,
                host="127.0.0.1",
                port=8765,
                access_log=False,
                log_level="critical",
            )
        )
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()

    def publish_services(self):
        with self.ledger.locked():
            self.ledger.save()
            self.controller.publish_service_associations(int(time.time()))

    def token(self, principal):
        authority = self.policy["authorities"]["fixture-pocket-id"]
        now = int(time.time())
        return jwt.encode(
            {
                "iss": authority["issuer"],
                "aud": authority["audience"],
                "sub": principal,
                "jti": secrets.token_hex(16),
                "client_id": "n05-fixture",
                "iat": now,
                "exp": now + 600,
                "groups": self.policy["principals"][principal]["groups"],
            },
            self.identity_key,
            algorithm="RS256",
            headers={"kid": "fixture-idp", "typ": "at+jwt"},
        )

    def resolver(self, method, path, body=None):
        with httpx.Client(trust_env=False, timeout=20) as client:
            response = client.request(
                method,
                "http://127.0.0.1:8765" + path,
                json=body,
                headers={"Authorization": "Bearer " + self.token("fixture-admin")},
            )
            if response.status_code not in (200, 202, 204):
                raise ValueError("resolver_fixture_request_failed")
            return None if response.status_code == 204 else response.json()

    def mint(self, kind, native_seconds=180):
        now = int(time.time())
        template_id = {
            "child": "child-client",
            "admin": "personal-client",
            "service": "whiskey-service",
            "legacy": "child-client",
        }[kind]
        principal = {
            "child": "fixture-child",
            "admin": "fixture-admin",
            "service": "fixture-text-service",
            "legacy": "fixture-child",
        }[kind]
        template = self.policy["model_templates"][template_id]
        instance = self.policy["instances"][template["instance"]]
        decision = None
        if kind in ("child", "admin"):
            with httpx.Client(trust_env=False, timeout=20) as policy_client:
                response = policy_client.post(
                    "http://127.0.0.1:8765/v1/policy/authorize",
                    headers={"Authorization": "Bearer " + self.token(principal)},
                    json={
                        "domain": template["domain"],
                        "instance": template["instance"],
                        "template_id": template_id,
                        "lifetime_seconds": 300,
                        "scopes": [],
                        "permissions": [],
                        "models": template["models"],
                        "routes": template["routes"],
                        "budget": template["budget"],
                    },
                )
                if response.status_code != 200:
                    raise ValueError("native_fixture_not_authorized")
                decision = response.json()["decision"]
        team = template["team"]
        with httpx.Client(trust_env=False, timeout=10) as client:
            if kind == "admin" and principal not in self.native_users:
                created_user = client.post(
                    ISSUER + "/user/new",
                    headers={"Authorization": "Bearer " + self.master},
                    json={
                        "user_id": principal,
                        "user_role": "proxy_admin",
                        "auto_create_key": False,
                    },
                )
                if (
                    created_user.status_code != 200
                    or created_user.json().get("user_role") != "proxy_admin"
                ):
                    raise ValueError("native_admin_owner_not_verified")
                self.native_users.add(principal)
            response = client.post(
                ISSUER + "/team/new",
                headers={"Authorization": "Bearer " + self.master},
                json={
                    "team_id": team,
                    "models": self.policy["teams"][team]["models"],
                },
            )
            if response.status_code != 200:
                current = client.get(
                    ISSUER + "/team/info",
                    headers={"Authorization": "Bearer " + self.master},
                    params={"team_id": team},
                )
                if current.status_code != 200:
                    raise ValueError("team_fixture_failed")
        raw = SecretStr("sk-" + secrets.token_urlsafe(32))
        digest = hashlib.sha256(raw.get_secret_value().encode()).hexdigest()
        expected = {
            "team_id": team,
            "user_id": principal if kind == "admin" else None,
            "models": template["models"],
            "allowed_routes": template["routes"],
            "max_budget": template["budget"]["usd"],
            "budget_duration": str(template["budget"]["duration_seconds"]) + "s",
            "permissions": {},
            "aliases": {},
            "config": {},
            "blocked": False,
            "router_settings": {
                "num_retries": 0,
                "fallbacks": [],
                "context_window_fallbacks": [],
                "model_group_alias": {},
            },
            "metadata": {
                "cc.owner": "command-center",
                "cc.principal": principal,
                "cc.domain": template["domain"],
                "cc.template": template_id,
            }
            if kind != "legacy"
            else {"fixture.owner": "unowned"},
        }
        if native_seconds not in (5, 180):
            raise ValueError("invalid_fixture_lifetime")
        self.native.generate({**expected, "duration": str(native_seconds) + "s"}, raw)
        record = self.native.info(digest)
        expires = self.native.verify(record, expected, now=now, deadline=now + 240)
        if kind == "service":
            with self.ledger.locked():
                self.ledger.state["keys"][digest] = {
                    "source": "controller",
                    "association": {
                        "issuer": ISSUER,
                        "credential_id": digest,
                        "native_key_id": digest,
                        "principal_id": principal,
                        "authority_id": "controller",
                        "domain": template["domain"],
                        "template_id": template_id,
                        "native_team_id": team,
                        "issued_at": now,
                        "expires_at": expires,
                        "device_id": None,
                        "state": "active",
                        "effective_limits": {
                            key: template[key] for key in ("models", "routes", "budget")
                        },
                    },
                }
                self.ledger.save()
                self.controller.publish_service_associations(now)
        elif kind != "legacy":
            metadata = ModelKeyMetadata(
                operation_id=secrets.token_hex(32),
                identity_sha256="1" * 64,
                binding_sha256="2" * 64,
                grant_id=decision["grant_id"],
                policy_revision=decision["policy_revision"],
                instance=template["instance"],
                audience=instance["audience"],
                team=team,
                models=tuple(template["models"]),
                routes=tuple(template["routes"]),
                budget=Budget.model_validate_json(json.dumps(template["budget"])),
                expected=expected,
                deadline=now + 240,
                status="prepared",
                native_known_created=True,
            )
            with self.state.transaction(write=True) as db:
                db.execute(
                    "INSERT INTO credential_associations "
                    "(issuer,credential_id,credential_sha256,principal_id,authority_id,domain,target,permissions_json,"
                    "template_id,issued_at,expires_at,admin_outage_eligible) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        ISSUER,
                        "sha256:" + digest,
                        digest,
                        principal,
                        "fixture-pocket-id",
                        template["domain"],
                        instance["target"],
                        metadata.model_dump_json(),
                        template_id,
                        now,
                        expires,
                        int(kind == "admin"),
                    ),
                )
            publish_associations(
                self.broker_settings.runtime_directory, self.state, self.broker_settings
            )
        self.keys[digest] = {"kind": kind, "raw": raw, "principal": principal}
        return {
            "key": raw.get_secret_value(),
            "hash": digest,
            "model": template["models"][0],
            "expires_at": expires,
        }

    def action(self, body):
        action = body["action"]
        if action == "mint":
            return self.mint(body["kind"], body.get("native_seconds", 180))
        if action == "deny":
            return self.resolver(
                "POST" if body.get("value", True) else "DELETE",
                "/v1/denies",
                {
                    "kind": "credential",
                    "issuer": ISSUER,
                    "identifier": "sha256:" + body["hash"],
                },
            )
        if action == "native_failure":
            value = (
                self.master if not body["value"] else "sk-" + secrets.token_urlsafe(32)
            )
            atomic_private_write(ROOT / "revocation-control", value.encode())
            return {"applied": True}
        if action == "drain":
            return self.resolver("POST", "/v1/denies/revocations/drain", {"limit": 8})
        if action == "feed":
            if body["mode"] == "capture":
                self.feed_backup = httpx.get(
                    "http://127.0.0.1:8765/v1/deny-feed", trust_env=False
                ).text
                return {"applied": True}
            self.feed_mode = body["mode"]
            if self.feed_mode == "signed-stale":
                now = int(time.time())
                with self.state.transaction(write=True) as db:
                    generation = (
                        db.execute("SELECT generation FROM deny_generation").fetchone()[
                            0
                        ]
                        + 100
                    )
                    db.execute("UPDATE deny_generation SET generation=?", (generation,))
                self.feed_override = self.signing.keyring.sign_deny(
                    DenyClaims(
                        iss=self.settings.signing.issuer,
                        generation=generation,
                        issued_at=now - body.get("age", 301),
                        fresh_until=now - body.get("age", 301) + 30,
                        principals=tuple(body.get("principals", [])),
                        credentials=(),
                        devices=(),
                    ),
                    now=now - body.get("age", 301),
                )
            elif self.feed_mode == "live":
                with self.state.transaction(write=True) as db:
                    db.execute("UPDATE deny_generation SET generation=generation+1")
            return {"applied": True}
        if action == "producer":
            name = body["producer"]
            path = ROOT / (
                "producer-r06/admission-associations.json"
                if name == "resolver"
                else "producer-n04/service-associations.json"
            )
            if body["mode"] == "capture":
                self.producer_backups[name] = path.read_bytes()
            elif body["mode"] == "rollback":
                latest = path.read_bytes()
                atomic_private_write(path, self.producer_backups[name])
                self.producer_backups[name] = latest
            elif body["mode"] == "restore":
                atomic_private_write(path, self.producer_backups[name])
            else:
                self.producer_backups[name] = path.read_bytes()
                if body["mode"] == "missing":
                    path.unlink()
                elif body["mode"] == "corrupt":
                    atomic_private_write(path, b"{}")
            return {"applied": True}
        if action == "lifecycle":
            key = body["hash"]
            with self.state.transaction(write=True) as db:
                row = db.execute(
                    "SELECT permissions_json FROM credential_associations WHERE credential_sha256=?",
                    (key,),
                ).fetchone()
                metadata = json.loads(row[0])
                metadata["status"] = body["status"]
                db.execute(
                    "UPDATE credential_associations SET permissions_json=? WHERE credential_sha256=?",
                    (json.dumps(metadata), key),
                )
            publish_associations(
                self.broker_settings.runtime_directory, self.state, self.broker_settings
            )
            return {"applied": True}
        if action == "policy":
            if body["mode"] == "exclude-child":
                self.policy_backup = json.dumps(self.policy).encode()
                self.policy["model_templates"]["child-client"]["acl"] = {
                    "principals": ["fixture-peer"],
                    "groups": [],
                }
                self.policy["principal_model_allowlists"]["fixture-child"] = {}
            elif body["mode"] == "restore" and self.policy_backup is not None:
                self.policy = json.loads(self.policy_backup)
            else:
                raise ValueError("invalid_policy_fixture_action")
            PolicyDocument.model_validate_json(json.dumps(self.policy))
            atomic_private_write(self.policy_path, json.dumps(self.policy).encode())
            return {"applied": True}
        if action == "clock":
            now = body["now"]
            if now is not None and (type(now) is not int or now <= 0):
                raise ValueError("invalid_fixture_clock")
            atomic_private_write(
                ROOT / "review-clock.json", json.dumps({"now": now}).encode()
            )
            return {"applied": True}
        if action == "status":
            state = json.loads(
                (ROOT / "admission-state/admission-state.json").read_text()
            )
            alert = ROOT / "admission-state/alerts/admin-freshness-alerts.jsonl"
            return {
                "known_owned": len(state["history"]),
                "feed_error": state["feed_error"],
                "last_now": state["last_now"],
                "alerts": []
                if not alert.exists()
                else [json.loads(row) for row in alert.read_text().splitlines()],
            }
        raise ValueError("unknown_fixture_action")


def main():
    logging.disable(logging.CRITICAL)
    inputs = json.loads(sys.stdin.readline())
    fixture = Fixture(inputs)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body, content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/jwks":
                self.reply(200, json.dumps({"keys": [fixture.jwk]}).encode())
            elif self.path == "/feed":
                if fixture.feed_mode == "missing":
                    self.reply(503, b"{}")
                elif fixture.feed_mode == "invalid":
                    self.reply(200, b"invalid", "application/jwt")
                elif fixture.feed_mode == "signed-stale":
                    self.reply(200, fixture.feed_override.encode(), "application/jwt")
                elif fixture.feed_mode == "replay":
                    self.reply(200, fixture.feed_backup.encode(), "application/jwt")
                else:
                    response = httpx.get(
                        "http://127.0.0.1:8765/v1/deny-feed", trust_env=False
                    )
                    self.reply(
                        response.status_code, response.content, "application/jwt"
                    )
            elif self.path == "/ready":
                self.reply(200 if fixture.server.started else 503, b"{}")
            else:
                self.reply(404, b"{}")

        def do_POST(self):
            if not secrets.compare_digest(
                self.headers.get("Authorization", ""), "Bearer " + fixture.control
            ):
                self.reply(401, b"{}")
                return
            try:
                size = int(self.headers.get("Content-Length", 0))
                if not 0 < size < 32768:
                    raise ValueError()
                result = fixture.action(json.loads(self.rfile.read(size)))
                self.reply(200, json.dumps(result).encode())
            except Exception as error:
                frame = traceback.extract_tb(error.__traceback__)[-1]
                self.reply(
                    503,
                    json.dumps(
                        {
                            "error": "fixture_action_failed",
                            "exception": type(error).__name__,
                            "file": Path(frame.filename).name,
                            "line": frame.lineno,
                        }
                    ).encode(),
                )

    ThreadingHTTPServer(("0.0.0.0", 9010), Handler).serve_forever()


if __name__ == "__main__":
    main()
