"""Provision only fresh synthetic runtime inputs using real bootstrap/signing contracts."""

import hashlib
import json
import os
import secrets
import time
from pathlib import Path

from atrium_profiles.crypto import public_jwk
from atrium_profiles.runtime import atomic_private_write, private_directory
from atrium_resolver.config import Bootstrap, Settings
from atrium_resolver.policy import PolicyEngine, PolicySeed
from atrium_resolver.signing import SigningService
from atrium_resolver.state import State
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from homelab_mcp.signing_key import _build_from_pem

from pki import key, material, pem_key

ROOT = Path("/run/atrium-n03")


def write(path, body, uid=0, *, mode=0o600):
    path = Path(path)
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(body)
        os.fchmod(stream.fileno(), mode)
        os.fchown(stream.fileno(), uid, uid)


def assign(directory, uid):
    for path in [directory, *directory.rglob("*")]:
        if path.is_symlink():
            raise ValueError("runtime_symlink_refused")
        os.chown(path, uid, uid)


def credentials(unit, uid, names, contents):
    directory = Path("/run/credentials") / (unit + ".service")
    directory.mkdir(mode=0o700)
    for name in names:
        write(directory / name, contents[name], uid)
    os.chown(directory, uid, uid)


def provision(f):
    for directory in (
        "/run/credentials",
        "/etc/atrium/desired-state",
        "/etc/atrium/n03",
    ):
        Path(directory).mkdir(mode=0o755, parents=True, exist_ok=True)
    for name, document in f["generated"].items():
        filename = {"homeMcp": "home-mcp"}.get(name, name)
        write(
            f"/etc/atrium/desired-state/{filename}.json",
            json.dumps(document).encode(),
            mode=0o444,
        )
    for name, document in (
        ("resolver", f["resolver"]),
        ("registration", f["registration"]),
        ("native-policy-template", f["nativePolicy"]),
        ("whiskey", f["whiskey"]),
        ("whiskey-model", f["whiskeyModel"]),
    ):
        write(f"/etc/atrium/n03/{name}.json", json.dumps(document).encode(), mode=0o444)
    write(ROOT / "fixture.json", json.dumps(f).encode(), mode=0o444)

    public = material(f)
    identity = key()
    public["identity-key"] = pem_key(identity)
    write(
        ROOT / "identity-jwks.json",
        json.dumps({"keys": [public_jwk(identity, "n03-identity")]}).encode(),
        mode=0o444,
    )
    native_key = _build_from_pem(pem_key(key()))
    public["native-jwks"] = json.dumps({"keys": [native_key.public_jwk]}).encode()

    resolver_state = private_directory(Path(f["state"]["resolver"]))
    signer_directory = private_directory(resolver_state / "signing")
    # Public settings name private credential paths; PKI inputs are installed before app startup.
    from atrium_resolver.signing import SigningSettings

    signing = SigningService(
        SigningSettings(directory=signer_directory, issuer=f["endpoints"]["resolver"])
    )
    signing.keyring.initialize(now=int(time.time()))
    public["resolver-jwks"] = json.dumps(
        signing.keyring.jwks(now=int(time.time()))
    ).encode()
    ids = f["ids"]
    resolver_uid = ids["atrium-resolver-fixture"]["uid"]
    resolver_keys = [
        "device-ca",
        "device-ca-key",
        "registration-cert",
        "registration-key",
        "native-ca",
        "native-client-cert",
        "native-client-key",
        "native-jwks",
        "front-ca",
    ]
    credentials("atrium-resolver", resolver_uid, resolver_keys, public)
    credentials("atrium-device-registration", resolver_uid, resolver_keys, public)
    credentials(
        "atrium-native-policy",
        resolver_uid,
        ["policy-server-cert", "policy-server-key", "policy-client-ca", "front-ca"],
        public,
    )
    policy_configuration = json.loads(json.dumps(f["nativePolicy"]))
    policy_leaf = x509.load_pem_x509_certificate(public["policy-client-cert"])
    policy_fingerprint = hashlib.sha256(
        policy_leaf.public_bytes(serialization.Encoding.DER)
    ).hexdigest()
    policy_configuration["native_policy"]["adapters"][0]["certificates"] = [
        policy_fingerprint
    ]
    Settings.model_validate_json(json.dumps(policy_configuration))
    write(
        ROOT / "native-policy.json",
        json.dumps(policy_configuration).encode(),
        resolver_uid,
    )
    native_uid = ids["atrium-mcp-fixture"]["uid"]
    credentials(
        "homelab-mcp",
        native_uid,
        [
            "server-cert",
            "server-key",
            "resolver-client-ca",
            "resolver-jwks",
            "front-ca",
            "policy-ca",
            "policy-client-cert",
            "policy-client-key",
        ],
        public,
    )
    credentials(
        "caddy",
        ids["atrium-caddy-fixture"]["uid"],
        ["front-cert", "front-key", "native-ca"],
        public,
    )
    credentials(
        "whiskey-whiskey-whiskey",
        ids["atrium-consumer-fixture"]["uid"],
        ["front-ca"],
        public,
    )

    config = Settings.model_validate_json(json.dumps(f["resolver"]))
    state = State(resolver_state)
    try:
        state.configure_authorities(config.authorities)
        policy = PolicyEngine(config, state)
        document, _ = policy.snapshot()
        enrollment = Bootstrap.model_validate_json(
            json.dumps(
                {
                    "principals": [
                        {
                            "id": name,
                            **{
                                key: value[key]
                                for key in ("display_name", "kind", "roles")
                            },
                        }
                        for name, value in f["generated"]["resolver"][
                            "principals"
                        ].items()
                    ],
                    "identities": [
                        {"principal": name, **binding}
                        for name, value in f["generated"]["resolver"][
                            "principals"
                        ].items()
                        for binding in value["bindings"]
                    ],
                }
            )
        )
        policy.validate_enrollment(enrollment)
        state.bootstrap(enrollment)
        grants = []
        for name, template in {
            **document.route_templates,
            **document.model_templates,
        }.items():
            if getattr(template, "credential_kind", "client") == "service":
                continue
            for principal in sorted(document.potential_members(template.acl)):
                record = document.principals[principal]
                if record.kind != "human":
                    continue
                binding = record.bindings[0]
                values = template.model_dump(mode="json")
                grants.append(
                    {
                        "id": f"n03-{principal}-{name}",
                        "principal": principal,
                        "authority": binding.authority,
                        "subject": binding.subject,
                        "expires_at": None,
                        "can_delegate": False,
                        "request": {
                            "domain": template.domain,
                            "instance": template.instance,
                            "template_id": name,
                            "scopes": values.get("scopes", []),
                            "permissions": values.get("permissions", []),
                            "models": values.get("models", []),
                            "routes": values.get("routes", []),
                            "budget": values.get("budget"),
                            "lifetime_seconds": min(template.max_lifetime_seconds, 900),
                        },
                    }
                )
        policy.seed_local(
            PolicySeed.model_validate_json(
                json.dumps(
                    {
                        "schema_version": 1,
                        "administrator": "ryan",
                        "grants": grants,
                    }
                )
            )
        )
    finally:
        state.close()
    assign(resolver_state, resolver_uid)
    for name, uid in (
        ("native", native_uid),
        ("whiskey", ids["atrium-consumer-fixture"]["uid"]),
    ):
        directory = private_directory(Path(f["state"][name]))
        if name == "native":
            atomic_private_write(directory / "signing-key.pem", native_key.private_pem)
        assign(directory, uid)
    caddy_state = private_directory(Path("/var/lib/caddy"))
    assign(caddy_state, ids["atrium-caddy-fixture"]["uid"])

    issuance = f["native"]["issuance"]
    cert = x509.load_pem_x509_certificate(public["native-client-cert"])
    issuance["tls"]["resolver_certificates"] = [
        hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    ]
    now = int(time.time())
    native_profile = {
        "resource": f["native"]["resource"],
        "cutover_at": now,
        "legacy_refresh_until": now + 604800,
    }
    native_env = {
        "HOMELAB_MCP_BIND_ADDRESS": "127.0.0.1",
        "HOMELAB_MCP_PORT": str(f["port"]),
        "HOMELAB_MCP_PUBLIC_BASE_URL": f["endpoints"]["native"],
        "HOMELAB_MCP_POCKETID_ISSUER": f["endpoints"]["identity"],
        "HOMELAB_MCP_POCKETID_CLIENT_ID": "atrium-n03-native",
        "HOMELAB_MCP_POCKETID_CLIENT_SECRET": secrets.token_urlsafe(32),
        "HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH": f["state"]["native"] + "/signing-key.pem",
        "HOMELAB_MCP_OAUTH_STATE_DB_PATH": f["state"]["native"] + "/state.db",
        "HOMELAB_MCP_ATRIUM_NATIVE": json.dumps(native_profile),
        "HOMELAB_MCP_ATRIUM_ISSUANCE": json.dumps(issuance),
        "HOMELAB_MCP_ATRIUM_DENY": json.dumps(f["native"]["deny"]),
        "HOMELAB_MCP_ATRIUM_POLICY": json.dumps(f["native"]["policy"]),
        "HOMELAB_MCP_ATRIUM_VIEW_POLICY": "/etc/atrium/desired-state/resolver.json",
        "HOMELAB_MCP_RESTRICTED_SCOPES": json.dumps(
            {
                name: scope["tools"]
                for name, scope in f["generated"]["resolver"]["catalogs"][
                    "home-mcp-fixture"
                ]["scopes"].items()
                if name != "admin" and scope["status"] == "active"
            }
        ),
        "HOMELAB_MCP_RESTRICTED_SCOPE_RESOURCES": json.dumps(
            {
                name: scope["resources"]
                for name, scope in f["generated"]["resolver"]["catalogs"][
                    "home-mcp-fixture"
                ]["scopes"].items()
                if name != "admin" and scope["status"] == "active"
            }
        ),
        "HOMELAB_MCP_GATUS_BASE_URL": "http://127.0.0.5:19101",
        "HOMELAB_MCP_FINANCES_REPO_URL": "file://"
        + f["state"]["native"]
        + "/synthetic-finances-origin",
        "HOMELAB_MCP_FINANCES_REPO_PATH": f["state"]["native"] + "/synthetic-finances",
        "HOMELAB_MCP_FINANCES_REPO_TOKEN": "",
        "HOMELAB_MCP_LOG_LEVEL": "warning",
    }
    public_env = (
        "\n".join(
            f"{name}='{native_env[name]}'"
            for name in ("HOMELAB_MCP_ATRIUM_NATIVE", "HOMELAB_MCP_ATRIUM_ISSUANCE")
        )
        + "\n"
    )
    write(ROOT / "native-public.env", public_env.encode())
    whiskey_env = {
        "PORT": "13417",
        "HOST": "127.0.0.1",
        "DATA_DIR": f["state"]["whiskey"],
        "NODE_ENV": "production",
        "LOG_LEVEL": "error",
        "WWW_ATRIUM_CONFIG": "/etc/atrium/n03/whiskey.json",
        "WWW_ATRIUM_MODEL_CONFIG": "/etc/atrium/n03/whiskey-model.json",
        "WWW_EXTERNAL_AS_ISSUER": f["endpoints"]["identity"],
        "WWW_EXTERNAL_AS_RESOURCE": "atrium-isolated-fixture",
        "WWW_OIDC_ISSUER": f["endpoints"]["identity"],
        "WWW_OIDC_CLIENT_ID": "atrium-n03-whiskey",
        "WWW_OIDC_REDIRECT_URI": f["endpoints"]["whiskey"] + "/api/auth/callback",
        "WWW_OIDC_CLIENT_SECRET": secrets.token_urlsafe(32),
        "WWW_PUBLIC_BASE_ORIGIN": f["endpoints"]["whiskey"],
        "NODE_EXTRA_CA_CERTS": "/run/credentials/whiskey-whiskey-whiskey.service/front-ca",
        "WWW_API_TOKEN": secrets.token_urlsafe(32),
        "WWW_SESSION_SECRET": secrets.token_urlsafe(48),
        "WWW_TOKEN_KEY": secrets.token_hex(32),
        "WWW_PUBLIC_TOKEN_KEY": secrets.token_hex(32),
        "WWW_GATE_TOKEN_KEY": secrets.token_hex(32),
    }
    fixture_uid = ids["atrium-identity-fixture"]["uid"]
    public["native-oidc-client"] = json.dumps(
        {
            "client_id": native_env["HOMELAB_MCP_POCKETID_CLIENT_ID"],
            "client_secret": native_env["HOMELAB_MCP_POCKETID_CLIENT_SECRET"],
            "redirect_uri": f["endpoints"]["native"] + "/oauth/callback",
        }
    ).encode()
    credentials(
        "atrium-n03-identity",
        fixture_uid,
        ["identity-key", "native-oidc-client"],
        public,
    )
    directory = private_directory(Path("/var/lib/atrium-n03-fixture"))
    assign(directory, fixture_uid)
    public_only = {
        name: value.decode()
        for name, value in public.items()
        if name in ("front-ca", "device-ca")
    }
    return {
        "native_environment": native_env,
        "whiskey_environment": whiskey_env,
        "identity_key": identity,
        "public": public_only,
        "native_ca": public["native-ca"].decode(),
        "native_client_material": {
            name: public[name]
            for name in (
                "native-client-cert",
                "native-client-key",
                "wrong-native-client-cert",
                "wrong-native-client-key",
            )
        },
        "policy_client_material": {
            name: public[name]
            for name in (
                "policy-client-cert",
                "policy-client-key",
                "wrong-policy-client-cert",
                "wrong-policy-client-key",
            )
        },
        "policy_fingerprint": policy_fingerprint,
        "policy_ca": public["policy-ca"].decode(),
    }
