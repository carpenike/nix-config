"""Owner-run fresh-sign-in preparation; no service activation or legacy migration."""

import argparse
import fcntl
import hashlib
import http.client
import json
import os
import pwd
import re
import sqlite3
import ssl
import stat
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Annotated
from urllib.parse import urlsplit

from atrium_profiles import ProfileError, PublicKeys
from atrium_profiles.models import ResourceURI, StrictModel
from atrium_resolver.config import Settings
from atrium_resolver.policy import PolicyDenied, PolicyEngine, PolicySeed
from atrium_resolver.policy_schema import PolicyConfigurationError, strict_json
from homelab_mcp.deny_config import NativeDenySettings
from homelab_mcp.deny_store import _Owner
from homelab_mcp.native_profile import NativeProfileSettings
from homelab_mcp.oauth_state import OAuthState, OAuthStateError
from homelab_mcp.view_policy import NativeViewRegistry, ViewPolicyError
from pydantic import Field, model_validator

MAX_JSON = 1024 * 1024
MAX_JWKS = 32768
PUBLIC_JWK_FIELDS = {"kty", "kid", "alg", "use", "key_ops", "n", "e"}
SIGNER_CHECK = """
import json, os, sys
from atrium_profiles import PublicKeys
from atrium_profiles.runtime import private_open
from homelab_mcp.signing_key import _build_from_pem
from pathlib import Path
descriptor = private_open(Path(sys.argv[1]), os.O_RDONLY)
with os.fdopen(descriptor, "rb") as stream:
    pem = stream.read(32769)
if not 0 < len(pem) <= 32768:
    raise ValueError("invalid_retained_signer")
signing = _build_from_pem(pem)
expected = PublicKeys(json.loads(sys.argv[2])).key(signing.kid)
retained = PublicKeys({"keys": [signing.public_jwk]}).key(signing.kid)
if expected.public_numbers() != retained.public_numbers():
    raise ValueError("retained_signer_mismatch")
"""


class Identity(StrictModel):
    """An existing numeric identity or a bounded, explicit NSS account name."""

    uid: Annotated[int, Field(gt=0, le=2**31 - 1)]
    gid: Annotated[int, Field(gt=0, le=2**31 - 1)]

    @model_validator(mode="before")
    @classmethod
    def resolve_account(cls, value):
        if not isinstance(value, str):
            return value
        if re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", value) is None:
            raise ValueError("invalid account reference")
        try:
            account = pwd.getpwnam(value)
        except KeyError:
            raise ValueError("unknown account reference") from None
        return {"uid": account.pw_uid, "gid": account.pw_gid}


class Configuration(StrictModel):
    schema_version: Annotated[int, Field(ge=1, le=1)]
    installation: Annotated[str, Field(pattern=r"^[a-z][a-z0-9_-]{0,63}$")]
    native_template: Path
    resolver_config: Path
    enrollment: Path
    tls_plan: Path
    policy_directory: Path
    native_signing_key: Path
    native_oauth_database: Path
    native_identity: Identity
    resolver_identity: Identity
    trust_identity: Identity
    resolver_command: Path
    native_bootstrap: Path
    native_bootstrap_config: Path
    finance_grants: Path
    native_issuer: ResourceURI = "https://mcp.holthome.net"
    native_jwks_url: ResourceURI = "https://mcp.holthome.net/oauth/jwks.json"
    resolver_jwks_url: ResourceURI = "https://atrium.holthome.net/.well-known/jwks.json"
    ca_bundle: Path = Path("/etc/ssl/certs/ca-certificates.crt")


class Rejected(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise Rejected(code)


def custody(path, *, uid=0, private=False, directory=False, runtime=False):
    require(path.is_absolute() and ".." not in path.parts, "invalid_path")
    require(path.resolve() == path, "symlink_input")
    if runtime:
        require(
            not path.is_relative_to("/nix/store")
            and not any((parent / ".git").exists() for parent in (path, *path.parents)),
            "runtime_custody_required",
        )
    for parent in path.parents:
        metadata = parent.lstat()
        require(
            stat.S_ISDIR(metadata.st_mode)
            and metadata.st_uid in (0, uid)
            and (
                not metadata.st_mode & 0o022
                or (parent == Path("/nix/store") and metadata.st_mode & stat.S_ISVTX)
            ),
            "unsafe_ancestor",
        )
    metadata = path.lstat()
    require(
        (stat.S_ISDIR if directory else stat.S_ISREG)(metadata.st_mode)
        and metadata.st_uid == uid
        and not metadata.st_mode & (0o077 if private else 0o022)
        and (
            directory
            or metadata.st_nlink == 1
            or (not private and path.is_relative_to("/nix/store"))
        ),
        "unsafe_custody",
    )
    return metadata


def public_path(path, *, executable=False):
    resolved = path.resolve()
    if resolved != path:
        # NixOS /etc publications and package executable links are the only
        # indirections accepted. Runtime inputs never get this exception.
        require(
            (path.is_relative_to("/etc") or path.is_relative_to("/nix/store"))
            and resolved.is_relative_to("/nix/store"),
            "symlink_input",
        )
        for part in (path, *path.parents):
            metadata = part.lstat()
            require(metadata.st_uid == 0, "foreign_public_input")
            require(
                stat.S_ISLNK(metadata.st_mode)
                or not metadata.st_mode & 0o022
                or (part == Path("/nix/store") and metadata.st_mode & stat.S_ISVTX),
                "unsafe_public_input",
            )
    metadata = custody(resolved)
    require(not executable or metadata.st_mode & 0o111, "invalid_executable")
    return resolved


def read_json(path, *, uid=0, private=False, public=False, maximum=MAX_JSON):
    if public:
        path = public_path(path)
    custody(path, uid=uid, private=private)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        body = stream.read(maximum + 1)
    require(0 < len(body) <= maximum, "invalid_document_size")
    return strict_json(body)


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def run(argv, identity, code):
    result = subprocess.run(
        [str(value) for value in argv],
        user=identity.uid,
        group=identity.gid,
        extra_groups=[],
        env={"HOME": "/", "LANG": "C.UTF-8", "PYTHONNOUSERSITE": "1"},
        cwd="/",
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=90,
        check=False,
        umask=0o077,
    )
    require(result.returncode == 0, code)


@contextmanager
def readonly_database(path, uid):
    custody(path.parent, uid=uid, private=True, directory=True, runtime=True)
    before = custody(path, uid=uid, private=True, runtime=True)
    require(before.st_size > 0, "missing_database")
    require(not os.path.lexists(str(path) + "-journal"), "database_recovery_required")
    sidecars = [Path(str(path) + suffix) for suffix in ("-wal", "-shm")]
    present = [os.path.lexists(sidecar) for sidecar in sidecars]
    require(all(present) or not any(present), "partial_database_sidecars")
    for sidecar, exists in zip(sidecars, present, strict=True):
        if exists:
            custody(sidecar, uid=uid, private=True, runtime=True)
    uri = path.as_uri() + "?mode=ro" + ("" if all(present) else "&immutable=1")
    connection = sqlite3.connect(uri, uri=True, isolation_level=None)
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        require(
            connection.execute("PRAGMA quick_check").fetchone()[0] == "ok",
            "database_integrity_failed",
        )
        yield connection
    finally:
        connection.close()
    after = custody(path, uid=uid, private=True, runtime=True)
    require(
        (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino),
        "database_replaced",
    )
    if not any(present):
        require(
            not any(os.path.lexists(sidecar) for sidecar in sidecars)
            and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            "database_changed_during_inspection",
        )


def require_native_schema(connection):
    """Compare retained history with the pinned app's schema, never initialize it."""
    reference = OAuthState.open(":memory:")
    try:
        require(reference._db is not None, "native_oauth_schema_unavailable")
        tables = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        required = {row[0] for row in reference._db.execute(tables)}
        observed = {row[0] for row in connection.execute(tables)}
        require(required <= observed, "native_oauth_history_schema_mismatch")
        columns = (
            'SELECT cid,name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info(?) ORDER BY cid"
        )
        for table in required:
            expected = [tuple(row) for row in reference._db.execute(columns, (table,))]
            actual = [tuple(row) for row in connection.execute(columns, (table,))]
            require(actual == expected, "native_oauth_history_schema_mismatch")
    finally:
        reference.close()


def public_keys(url, ca_bundle):
    parsed = urlsplit(url)
    require(
        parsed.scheme == "https"
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment,
        "invalid_public_endpoint",
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cafile=str(public_path(ca_bundle)))
    connection = http.client.HTTPSConnection(
        parsed.hostname,
        parsed.port or 443,
        context=context,
        timeout=10,
    )
    try:
        connection.request(
            "GET",
            parsed.path,
            headers={"Accept": "application/json", "Accept-Encoding": "identity"},
        )
        response = connection.getresponse()
        require(response.status == 200, "public_keys_http_rejected")
        require(
            response.getheader("Content-Encoding", "identity") == "identity",
            "encoded_public_keys",
        )
        length = response.getheader("Content-Length")
        require(
            length is None or (length.isdecimal() and int(length) <= MAX_JWKS),
            "oversized_public_keys",
        )
        body = response.read(MAX_JWKS + 1)
        require(0 < len(body) <= MAX_JWKS, "oversized_public_keys")
        document = strict_json(body)
        require(isinstance(document, dict), "invalid_public_keys")
        PublicKeys(document)
        require(
            all(set(key) <= PUBLIC_JWK_FIELDS for key in document["keys"]),
            "nonpublic_key_fields",
        )
        require(len(encoded(document)) <= MAX_JWKS, "oversized_public_keys")
        return document
    finally:
        connection.close()


def deny_owner(settings, native_issuer, uid):
    directory = settings.state_directory
    custody(directory.parent, uid=uid, private=True, directory=True, runtime=True)
    if not os.path.lexists(directory):
        return None
    custody(directory, uid=uid, private=True, directory=True, runtime=True)
    entries = set(os.listdir(directory))
    if not entries:
        return None
    require(
        {"owner.json", "denial.sqlite"} <= entries
        and entries
        <= {
            "owner.json",
            "denial.sqlite",
            "denial.sqlite-wal",
            "denial.sqlite-shm",
            "initialization.lock",
            "initialization.started",
        },
        "partial_deny_history",
    )
    for name in entries:
        custody(directory / name, uid=uid, private=True, runtime=True)
    owner = _Owner.model_validate_json(
        json.dumps(
            read_json(directory / "owner.json", uid=uid, private=True, maximum=1024),
        )
    )
    require(owner.binding == settings.binding(native_issuer), "deny_binding_conflict")
    return owner


def finance_state(configuration, settings, seed, views):
    with readonly_database(
        settings.state_directory / "resolver.sqlite3",
        configuration.resolver_identity.uid,
    ) as connection:
        rows = [
            connection.execute(
                "SELECT * FROM grants WHERE id=?", (grant.id,)
            ).fetchone()
            for grant in seed.grants
        ]
        if all(row is None for row in rows):
            return "append"
        require(all(row is not None for row in rows), "partial_finance_grants")
        for grant, row in zip(seed.grants, rows, strict=True):
            record = PolicyEngine._grant(row, int(time.time()))
            resource = views.view(grant.request.instance).resource
            require(
                PolicyEngine._grant_request(record) == grant.request
                and (record.principal, record.authority, record.subject)
                == (grant.principal, grant.authority, grant.subject)
                and record.expires_at == grant.expires_at
                and record.can_delegate == grant.can_delegate
                and record.grantor_id == seed.administrator
                and record.source == "local-bootstrap"
                and record.parent_grant_id is None
                and (record.target, record.audience, record.adapter)
                == (resource.target, resource.audience, "home-mcp"),
                "finance_grant_conflict",
            )
    return "reuse"


def existing_output(directory, name):
    path = directory / name
    if not os.path.lexists(path):
        return None
    value = read_json(path, private=True)
    require(isinstance(value, dict), "invalid_existing_artifact")
    return value


def preflight(configuration):
    c = configuration
    for identity in (c.native_identity, c.resolver_identity, c.trust_identity):
        require(pwd.getpwuid(identity.uid).pw_gid == identity.gid, "identity_mismatch")
    require(
        len({c.native_identity.uid, c.resolver_identity.uid, c.trust_identity.uid})
        == 3,
        "distinct_service_identities_required",
    )
    custody(c.policy_directory, directory=True, runtime=True)
    public_path(c.resolver_command, executable=True)
    public_path(c.native_bootstrap)
    public_path(c.enrollment)
    public_path(c.tls_plan)
    template = read_json(c.native_template, public=True)
    require(
        set(template) == {"profile_path", "resource", "issuance", "policy", "deny"},
        "invalid_native_template",
    )
    settings = Settings.model_validate_json(
        json.dumps(read_json(c.resolver_config, public=True))
    )
    require(
        settings.policy_path is not None and settings.signing is not None,
        "missing_foundation_binding",
    )
    policy = public_path(settings.policy_path)
    require(
        public_path(Path(template["issuance"]["policy_path"])) == policy
        and template["issuance"]["resolver_issuer"] == settings.signing.issuer
        and template["policy"]["resolver_issuer"] == settings.signing.issuer,
        "policy_binding_conflict",
    )
    deny = NativeDenySettings.model_validate_json(json.dumps(template["deny"]))
    require(
        c.native_jwks_url == c.native_issuer + "/oauth/jwks.json"
        and c.resolver_jwks_url == settings.signing.issuer + "/.well-known/jwks.json"
        and c.resolver_jwks_url == deny.jwks_url
        and deny.issuer == settings.signing.issuer,
        "public_endpoint_binding_conflict",
    )
    require(
        read_json(c.native_bootstrap_config, public=True)
        == {
            "installation": c.installation,
            "native_issuer": c.native_issuer,
            "deny": template["deny"],
        },
        "bootstrap_binding_conflict",
    )
    views = NativeViewRegistry(
        SimpleNamespace(
            issuer=c.native_issuer,
            atrium_view_policy=policy,
            atrium_issuance=None,
        )
    )
    old_profile = existing_output(c.policy_directory, "native-profile.json")
    now = int(time.time())
    profile = NativeProfileSettings.model_validate_json(
        json.dumps(
            old_profile
            if old_profile is not None
            else {
                "resource": template["resource"],
                "cutover_at": now,
                "legacy_refresh_until": now,
                "legacy_mappings": [],
            },
        )
    )
    require(
        profile.cutover_at == profile.legacy_refresh_until
        and not profile.legacy_mappings
        and profile.cutover_at <= int(time.time())
        and profile.resource.model_dump(mode="json") == template["resource"]
        and views.for_path("/mcp").resource == profile.resource,
        "fresh_profile_binding_conflict",
    )
    seed = PolicySeed.model_validate_json(
        json.dumps(read_json(c.finance_grants, public=True))
    )
    expected_views = {"personal-finance", "personal-scribe", "personal-status"}
    if any(view.resource.id == "personal-money" for view in views.active_views()):
        expected_views.add("personal-money")
    require(
        len(seed.grants) == len(expected_views)
        and {grant.request.instance for grant in seed.grants} == expected_views,
        "exact_finance_plan_required",
    )
    for grant in seed.grants:
        view = views.view(grant.request.instance)
        declared = view.policy.route_templates[grant.request.template_id]
        require(
            grant.principal == view.instance.owner_principal == seed.administrator
            and grant.authority == template["policy"]["authority"]
            and not grant.can_delegate
            and grant.expires_at is None
            and grant.id == grant.request.template_id + ".baseline"
            and grant.request.domain == view.resource.domain == profile.resource.domain
            and declared.status == "active"
            and declared.instance == view.resource.id
            and grant.request.lifetime_seconds == declared.max_lifetime_seconds == 900
            and grant.request.scopes == declared.scopes
            and not grant.request.permissions
            and not grant.request.models
            and not grant.request.routes
            and grant.request.budget is None,
            "finance_plan_binding_conflict",
        )
    run(
        [
            c.resolver_command,
            "--config",
            c.resolver_config,
            "check-foundation",
            "--enrollment",
            c.enrollment,
            "--installation",
            c.installation,
        ],
        c.resolver_identity,
        "foundation_check_failed",
    )
    run(
        [
            c.resolver_command,
            "--config",
            c.resolver_config,
            "tls",
            "--plan",
            c.tls_plan,
            "status",
        ],
        c.trust_identity,
        "trust_check_failed",
    )
    custody(
        c.native_signing_key.parent,
        uid=c.native_identity.uid,
        private=True,
        directory=True,
        runtime=True,
    )
    require(
        custody(
            c.native_signing_key, uid=c.native_identity.uid, private=True, runtime=True
        ).st_size
        > 0,
        "missing_retained_signer",
    )
    owner = deny_owner(deny, c.native_issuer, c.native_identity.uid)
    with readonly_database(
        c.native_oauth_database, c.native_identity.uid
    ) as connection:
        require_native_schema(connection)
        cutover = connection.execute(
            "SELECT * FROM native_profile_cutover WHERE singleton=1"
        ).fetchone()
        if cutover is not None:
            require(
                old_profile is not None
                and cutover["issuer"] == c.native_issuer
                and cutover["cutover_at"] == profile.cutover_at
                and cutover["legacy_refresh_until"] == profile.legacy_refresh_until
                and strict_json(cutover["resource_json"]) == template["resource"],
                "retained_cutover_conflict",
            )
        adopted = connection.execute(
            "SELECT * FROM native_deny_adoption WHERE singleton=1"
        ).fetchone()
        require(
            adopted is None
            or (
                owner is not None
                and adopted["binding"] == owner.binding
                and adopted["installation"] == owner.installation
            ),
            "retained_deny_history_missing",
        )
    grants = finance_state(c, settings, seed, views)
    documents = {
        "native-profile.json": profile.model_dump(mode="json"),
        "native-jwks.json": public_keys(c.native_jwks_url, c.ca_bundle),
        "resolver-jwks.json": public_keys(c.resolver_jwks_url, c.ca_bundle),
    }
    run(
        [
            sys.executable,
            "-I",
            "-B",
            "-c",
            SIGNER_CHECK,
            c.native_signing_key,
            json.dumps(documents["native-jwks.json"]),
        ],
        c.native_identity,
        "retained_signer_mismatch",
    )
    for name, expected in documents.items():
        current = existing_output(c.policy_directory, name)
        require(
            current is None or digest(current) == digest(expected),
            "existing_public_artifact_conflict",
        )
    receipt = existing_output(c.policy_directory, "native-adoption.approved")
    if receipt is not None:
        require(
            owner is not None
            and grants == "reuse"
            and all(os.path.lexists(c.policy_directory / name) for name in documents)
            and digest(receipt) == digest(approval(c, documents, seed, owner)),
            "approval_conflict",
        )
    return settings, deny, views, seed, owner, documents, grants


def approval(configuration, documents, seed, owner):
    return {
        "schema_version": 1,
        "installation": configuration.installation,
        "transition": "fresh-sign-in",
        "cutover_at": documents["native-profile.json"]["cutover_at"],
        "documents": {name: digest(value) for name, value in documents.items()},
        "finance_grants_sha256": digest(seed.model_dump(mode="json")),
        "deny_binding": owner.binding,
        "deny_installation": owner.installation,
    }


def publish(directory, name, value):
    current = existing_output(directory, name)
    if current is not None:
        require(digest(current) == digest(value), "publication_conflict")
        return
    pending = directory / ("." + name + ".new")
    descriptor = os.open(
        pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(pending, directory / name, follow_symlinks=False)
    finally:
        pending.unlink()
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


DENY_CHECK = """
import sys
from homelab_mcp.deny_config import NativeDenySettings
from homelab_mcp.deny_store import DenyStore
settings = NativeDenySettings.model_validate_json(sys.argv[1])
store = DenyStore(settings, binding=settings.binding(sys.argv[2]), expected_installation=sys.argv[3])
store.close()
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm-installation")
    args = parser.parse_args()
    try:
        require(os.geteuid() == 0, "owner_root_required")
        configuration = Configuration.model_validate_json(
            json.dumps(read_json(args.config, public=True))
        )
        c = configuration
        require(
            (args.apply and args.confirm_installation == c.installation)
            or (not args.apply and args.confirm_installation is None),
            "explicit_apply_confirmation_required",
        )
        custody(c.policy_directory, directory=True, runtime=True)
        descriptor = os.open(
            c.policy_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            settings, deny, views, seed, owner, documents, grants = preflight(c)
            result = {
                "mode": "apply" if args.apply else "plan",
                "fresh_sign_in": True,
                "cutover_at": documents["native-profile.json"]["cutover_at"],
                "deny_history": "initialize" if owner is None else "reuse",
                "finance_grants": grants,
                "approved": False,
                "deny_validation": "on-apply",
            }
            if args.apply:
                for name, value in documents.items():
                    publish(c.policy_directory, name, value)
                if owner is None:
                    run(
                        [
                            sys.executable,
                            "-I",
                            "-B",
                            c.native_bootstrap,
                            "--config",
                            c.native_bootstrap_config,
                            "--confirm-new-installation",
                            c.installation,
                        ],
                        c.native_identity,
                        "deny_initialization_failed",
                    )
                    owner = deny_owner(deny, c.native_issuer, c.native_identity.uid)
                require(owner is not None, "deny_history_missing")
                run(
                    [
                        sys.executable,
                        "-I",
                        "-B",
                        "-c",
                        DENY_CHECK,
                        deny.model_dump_json(),
                        c.native_issuer,
                        owner.installation,
                    ],
                    c.native_identity,
                    "deny_validation_failed",
                )
                if grants == "append":
                    run(
                        [
                            c.resolver_command,
                            "--config",
                            c.resolver_config,
                            "seed-policy",
                            "--append",
                            "--grants",
                            c.finance_grants,
                        ],
                        c.resolver_identity,
                        "finance_append_failed",
                    )
                require(
                    finance_state(c, settings, seed, views) == "reuse",
                    "finance_append_unverified",
                )
                publish(
                    c.policy_directory,
                    "native-adoption.approved",
                    approval(c, documents, seed, owner),
                )
                result.update(approved=True, deny_validation="verified")
            print(json.dumps(result, sort_keys=True))
        finally:
            os.close(descriptor)
    except Rejected as error:
        raise SystemExit("atrium_native_cutover_rejected:" + str(error)) from None
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        RecursionError,
        sqlite3.Error,
        ProfileError,
        ViewPolicyError,
        PolicyDenied,
        PolicyConfigurationError,
        OAuthStateError,
        http.client.HTTPException,
        subprocess.TimeoutExpired,
    ):
        raise SystemExit(
            "atrium_native_cutover_rejected:invalid_configuration_or_state"
        ) from None


if __name__ == "__main__":
    main()
