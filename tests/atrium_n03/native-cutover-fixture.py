"""Private /run-only integration driver for the owner preparation command."""

import argparse
import asyncio
import copy
import hashlib
import http.client
import json
import os
import pwd
import secrets
import signal
import sqlite3
import ssl
import stat
import subprocess
import sys
import time
import traceback
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from atrium_profiles import PublicKeys
from homelab_mcp.native_profile import NativeProfileSettings

ENVIRONMENT = {"HOME": "/", "LANG": "C.UTF-8", "PYTHONNOUSERSITE": "1"}
STEP = "setup"


def load(path):
    return json.loads(Path(path).read_bytes())


def write(path, value, *, mode=0o644, identity=None):
    body = (
        value
        if isinstance(value, bytes)
        else json.dumps(value, sort_keys=True).encode()
    )
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode
    )
    with os.fdopen(descriptor, "wb") as stream:
        os.fchmod(stream.fileno(), mode)
        if identity is not None:
            os.fchown(stream.fileno(), identity["uid"], identity["gid"])
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())


def replace(path, value):
    path = Path(path)
    metadata = path.stat()
    pending = path.with_name("." + path.name + ".fixture-replacement")
    write(
        pending,
        value,
        mode=stat.S_IMODE(metadata.st_mode),
        identity={"uid": metadata.st_uid, "gid": metadata.st_gid},
    )
    os.replace(pending, path)


def directory(path, identity=None):
    mode = 0o700 if identity else 0o755
    Path(path).mkdir(mode=mode)
    Path(path).chmod(mode)
    if identity:
        os.chown(path, identity["uid"], identity["gid"])


def executed(argv, identity=None):
    kwargs = (
        {}
        if identity is None
        else {
            "user": identity["uid"],
            "group": identity["gid"],
            "extra_groups": [],
        }
    )
    return subprocess.run(
        [str(value) for value in argv],
        env=ENVIRONMENT,
        cwd="/",
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=100,
        check=False,
        umask=0o077,
        **kwargs,
    )


def successful(argv, identity=None):
    result = executed(argv, identity)
    assert result.returncode == 0, "fixture_application_command_failed"
    return result.stdout


def background(argv, identity):
    return subprocess.Popen(
        [str(value) for value in argv],
        env=ENVIRONMENT,
        cwd="/",
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        user=identity["uid"],
        group=identity["gid"],
        extra_groups=[],
        umask=0o077,
    )


def wait_for(predicate, process):
    for _ in range(150):
        assert process.poll() is None, "fixture_background_exited"
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("fixture_background_not_ready")


def native_history(configuration):
    from homelab_mcp.config import Settings
    from homelab_mcp.oauth_state import IssuedRefreshToken, OAuthState
    from homelab_mcp.signing_key import load_or_create

    state_path = Path(configuration["native_oauth_database"])
    native = state_path.parent
    signing = load_or_create(
        Settings(
            _env_file=None,
            public_base_url=configuration["native_issuer"],
            oauth_signing_key_path=configuration["native_signing_key"],
            pocketid_issuer="https://identity.atrium.invalid",
            pocketid_client_id="synthetic-native",
            pocketid_client_secret=secrets.token_urlsafe(32),
        )
    )
    write(native / "public-jwks.json", {"keys": [signing.public_jwk]}, mode=0o600)
    state = OAuthState.open(str(state_path))

    async def seed():
        client = await state.register_client(
            redirect_uris=["https://client.atrium.invalid/callback"],
            client_name="Synthetic retained native client",
            token_endpoint_auth_method="client_secret_post",
        )
        ancestor, current = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        payload = IssuedRefreshToken(
            client_id=client.client_id,
            user_email="synthetic@atrium.invalid",
            expires_at=time.time() + 86400,
            scope="advisor",
            family_id=secrets.token_hex(16),
        )
        assert await state.store_refresh(ancestor, payload)
        assert (
            await state.consume_refresh(ancestor, client_id=client.client_id)
            is not None
        )
        assert await state.store_refresh(current, payload)
        return client.client_id, ancestor, current

    client_id, ancestor, current = asyncio.run(seed())

    async def replay():
        assert await state.consume_refresh(ancestor, client_id=client_id) is None
        assert await state.consume_refresh(current, client_id=client_id) is None
        assert (
            state._db.execute("SELECT count(*) FROM revoked_refresh_family").fetchone()[
                0
            ]
            == 1
        )

    write(native / "ready", b"ready\n", mode=0o600)
    stopped = False
    replay_checked = False

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    try:
        while not stopped:
            if not replay_checked and (native / "check-replay").exists():
                state.close()
                state = OAuthState.open(str(state_path))
                asyncio.run(replay())
                write(native / "replay-preserved", b"verified\n", mode=0o600)
                replay_checked = True
            time.sleep(0.1)
    finally:
        state.close()


def serve_public_keys(fixture, configuration):
    root = Path(fixture["root"])

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path == "/redirect-target":
                write(
                    root / "public-server" / "redirect-followed",
                    b"unexpected\n",
                    mode=0o600,
                )
                self.send_error(500)
                return
            name = {
                "/oauth/jwks.json": "native",
                "/.well-known/jwks.json": "resolver",
            }.get(self.path)
            if name is None:
                self.send_error(404)
                return
            mode = load(root / "server-mode.json")[name]
            if mode == "redirect":
                self.send_response(302)
                self.send_header(
                    "Location", configuration["native_issuer"] + "/redirect-target"
                )
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            document = load(root / f"public-{name}-jwks.json")
            if mode == "private":
                document["keys"][0]["d"] = "DO-NOT-LOG-PRIVATE-FIELD"
            elif mode == "invalid-key":
                document["keys"][0]["n"] = "AA"
            elif mode == "changed-key":
                document = load(root / "public-resolver-jwks.json")
            body = json.dumps(document).encode()
            if mode == "malformed":
                body = b'{"keys":DO-NOT-LOG-BODY'
            elif mode == "duplicate":
                body = b'{"keys":[],"keys":[]}'
            elif mode in ("oversized", "unbounded"):
                body = b" " * 32769
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            if mode != "unbounded":
                self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = HTTPServer(("127.0.0.1", 18443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(
        root / "trust" / "native-server.crt.pem",
        root / "trust" / "native-server.key.pem",
    )
    server.socket = context.wrap_socket(server.socket, server_side=True)
    write(root / "public-server" / "ready", b"ready\n", mode=0o600)
    server.serve_forever()


def populate_denial(configuration):
    from atrium_profiles.crypto import public_jwk
    from atrium_profiles.deny import DenyClaims, FreshnessException, sign_deny_document
    from atrium_profiles.models import IssuerQualifiedCredential
    from cryptography.hazmat.primitives.asymmetric import rsa
    from homelab_mcp.deny_config import NativeDenySettings
    from homelab_mcp.deny_store import DenyStore

    template = load(configuration["native_template"])
    settings = NativeDenySettings.model_validate_json(json.dumps(template["deny"]))
    store = DenyStore(
        settings, binding=settings.binding(configuration["native_issuer"])
    )
    now = int(time.time())
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    document = sign_deny_document(
        DenyClaims(
            iss=settings.issuer,
            generation=9,
            issued_at=now,
            fresh_until=now + 30,
            principals=("synthetic-denied",),
            credentials=(),
            devices=("synthetic-device",),
        ),
        key,
        kid="synthetic-history",
    )
    store.receive(
        document,
        {"keys": [public_jwk(key, "synthetic-history")]},
        deadline=time.monotonic() + 5,
    )
    with store._transaction() as connection:
        store._alert(
            connection,
            FreshnessException(
                timestamp=now - 60,
                principal="fixture-owner",
                domain="personal:fixture-owner",
                credential=IssuerQualifiedCredential(
                    configuration["native_issuer"], "synthetic-alert"
                ),
                device=None,
                reason="stale",
                generation=8,
            ),
        )
    store.close()


def fingerprint(path):
    path = Path(path)
    metadata = path.stat()
    return (
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_gid,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_mtime_ns,
        hashlib.sha256(path.read_bytes()).digest(),
    )


def retained(configuration):
    settings = load(configuration["resolver_config"])
    paths = [
        Path(configuration["native_signing_key"]),
        Path(configuration["native_oauth_database"]),
        Path(configuration["native_oauth_database"] + "-wal"),
    ]
    paths += sorted(Path(settings["signing"]["directory"]).iterdir())
    paths += sorted(
        path
        for path in Path(load(configuration["tls_plan"])["directory"]).iterdir()
        if path.suffix == ".pem"
    )
    return {str(path): fingerprint(path) for path in paths}


def query(path, sql, args=()):
    path = Path(path)
    uri = path.as_uri() + "?mode=ro"
    if not Path(str(path) + "-wal").exists():
        uri += "&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    try:
        return connection.execute(sql, args).fetchall()
    finally:
        connection.close()


def change(path, sql, args=()):
    connection = sqlite3.connect(path)
    try:
        connection.execute(sql, args)
        connection.commit()
    finally:
        connection.close()


def clone_database(source, destination, identity):
    reader = sqlite3.connect(Path(source).as_uri() + "?mode=ro", uri=True)
    writer = sqlite3.connect(destination)
    try:
        reader.backup(writer)
    finally:
        reader.close()
        writer.close()
    destination.chmod(0o600)
    os.chown(destination, identity["uid"], identity["gid"])


def deny_snapshot(configuration):
    directory = Path(load(configuration["native_template"])["deny"]["state_directory"])
    rows = query(
        directory / "denial.sqlite", "SELECT installation,document FROM snapshot"
    )
    saved = json.loads(rows[0][1])
    last_now = saved.pop("last_now")
    return (
        (directory / "owner.json").read_bytes(),
        rows[0][0],
        saved,
        query(
            directory / "denial.sqlite",
            "SELECT id,document FROM freshness_alerts ORDER BY id",
        ),
    ), last_now


@contextmanager
def edited(path, value):
    original = Path(path).read_bytes()
    replace(path, value)
    try:
        yield
    finally:
        replace(path, original)


def tests(fixture_path, fixture, configuration):
    global STEP
    root = Path(fixture["root"])
    assert root.is_relative_to("/run") and not root.exists(), (
        "private_fresh_fixture_required"
    )
    os.umask(0o077)
    directory(root)
    directory(root / "policy")
    for name, identity in (
        ("native", configuration["native_identity"]),
        ("resolver", configuration["resolver_identity"]),
        ("trust", configuration["trust_identity"]),
        ("public-server", configuration["trust_identity"]),
    ):
        directory(root / name, identity)
    resolver = [
        configuration["resolver_command"],
        "--config",
        configuration["resolver_config"],
    ]
    successful(
        resolver + ["bootstrap", "--enrollment", configuration["enrollment"]],
        configuration["resolver_identity"],
    )
    successful(resolver + ["signing", "initialize"], configuration["resolver_identity"])
    successful(
        resolver + ["seed-policy", "--grants", fixture["ordinary_grants"]],
        configuration["resolver_identity"],
    )
    write(
        root / "resolver" / "foundation.initialized",
        (configuration["installation"] + "\n").encode(),
        mode=0o600,
        identity=configuration["resolver_identity"],
    )
    successful(
        resolver + ["tls", "--plan", configuration["tls_plan"], "initialize"],
        configuration["trust_identity"],
    )
    successful(
        resolver + ["tls", "--plan", configuration["tls_plan"], "status"],
        configuration["trust_identity"],
    )
    trust_members = {path.name for path in (root / "trust").iterdir()}
    write(root / "public-ca.pem", (root / "trust" / "native-ca.crt.pem").read_bytes())
    write(
        root / "native" / "public-ca.pem",
        (root / "public-ca.pem").read_bytes(),
        mode=0o600,
        identity=configuration["native_identity"],
    )
    write(
        root / "public-resolver-jwks.json",
        json.loads(
            successful(
                resolver + ["signing", "jwks"], configuration["resolver_identity"]
            )
        ),
    )
    write(root / "server-mode.json", {"native": "valid", "resolver": "valid"})
    phase_command = [
        sys.executable,
        "-I",
        "-B",
        __file__,
        "--fixture",
        fixture_path,
        "--phase",
    ]
    native = background(
        phase_command + ["native-history"], configuration["native_identity"]
    )
    server = None
    try:
        wait_for(lambda: (root / "native" / "ready").exists(), native)
        write(
            root / "public-native-jwks.json", load(root / "native" / "public-jwks.json")
        )
        server = background(
            phase_command + ["public-server"], configuration["trust_identity"]
        )
        wait_for(lambda: (root / "public-server" / "ready").exists(), server)
        assert {path.name for path in (root / "trust").iterdir()} == trust_members
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cafile=str(root / "public-ca.pem"))
        connection = http.client.HTTPSConnection(
            "native.atrium.invalid", 18443, context=context, timeout=5
        )
        connection.request("GET", "/oauth/jwks.json")
        response = connection.getresponse()
        assert response.status == 200
        PublicKeys(json.loads(response.read()))
        connection.close()

        baseline = retained(configuration)
        database = root / "resolver" / "resolver.sqlite3"
        ordinary = query(database, "SELECT * FROM grants ORDER BY id")
        assert len(ordinary) == 1
        native_database = Path(configuration["native_oauth_database"])
        for table in ("oauth_client", "refresh_token", "consumed_refresh"):
            assert query(native_database, f"SELECT count(*) FROM {table}") == [(1,)]
        artifacts = (
            "native-profile.json",
            "native-jwks.json",
            "resolver-jwks.json",
            "native-adoption.approved",
        )
        results = []

        def invoke(
            path=fixture["config"],
            *,
            apply=False,
            confirmation=None,
            failure=None,
            identity=None,
        ):
            argv = [sys.executable, "-I", "-B", fixture["helper"], "--config", path]
            if apply:
                argv += ["--apply"]
            if confirmation is not None:
                argv += ["--confirm-installation", confirmation]
            result = executed(argv, identity)
            assert b"DO-NOT-LOG" not in result.stdout + result.stderr, (
                "sensitive_output"
            )
            if failure is not None:
                assert result.returncode != 0 and not result.stdout, "refusal_required"
                assert b"atrium_native_cutover_rejected:" in result.stderr, (
                    "fixed_failure_required"
                )
                if failure:
                    assert failure.encode() in result.stderr, "unexpected_refusal"
                return None
            assert result.returncode == 0, "preparation_failed"
            return json.loads(result.stdout)

        def apply(path=fixture["config"], *, failure=None):
            return invoke(
                path,
                apply=True,
                confirmation=configuration["installation"],
                failure=failure,
            )

        def variant(name, **changes):
            value = configuration | changes
            path = root / f"{name}.json"
            write(path, value)
            return path

        def template_variant(name, template, **changes):
            template_path = root / f"{name}-native.json"
            bootstrap_path = root / f"{name}-deny.json"
            write(template_path, template)
            write(
                bootstrap_path,
                {
                    "installation": configuration["installation"],
                    "native_issuer": configuration["native_issuer"],
                    "deny": template["deny"],
                },
            )
            return variant(
                name,
                native_template=str(template_path),
                native_bootstrap_config=str(bootstrap_path),
                **changes,
            )

        def untouched():
            assert not list((root / "policy").iterdir()), "plan_wrote_publication"
            assert not (root / "native" / "denial").exists(), "plan_initialized_denial"
            assert query(database, "SELECT * FROM grants ORDER BY id") == ordinary, (
                "ordinary_grants_changed"
            )
            assert retained(configuration) == baseline, "retained_state_changed"
            assert {
                path.name for path in (root / "trust").iterdir()
            } == trust_members, "extra_tls_files"

        STEP = "read-only-plan-and-consent"
        planned = invoke()
        assert planned["mode"] == "plan" and not planned["approved"]
        assert (
            planned["deny_validation"] == "on-apply"
            and planned["finance_grants"] == "append"
        )
        invoke(apply=True, failure="explicit_apply_confirmation_required")
        invoke(
            apply=True,
            confirmation="another-installation",
            failure="explicit_apply_confirmation_required",
        )
        invoke(
            confirmation=configuration["installation"],
            failure="explicit_apply_confirmation_required",
        )
        invoke(identity=configuration["native_identity"], failure="owner_root_required")
        invoke(variant("extra-command", command=["sh", "-c", "true"]), failure="")
        invoke(variant("boolean-schema", schema_version=True), failure="")
        untouched()
        results.append(STEP)

        STEP = "named-identity-plan-and-refusals"
        native_name = pwd.getpwuid(configuration["native_identity"]["uid"]).pw_name
        named_config = variant("named-native-account", native_identity=native_name)
        named_plan = invoke(named_config)
        assert named_plan["mode"] == "plan" and not named_plan["approved"]
        assert named_plan["deny_history"] == "initialize"
        assert named_plan["finance_grants"] == "append"
        untouched()
        for name, reference in (
            ("unknown", "atrium-missing-fixture"),
            ("root", "root"),
            ("invalid", "../homelab-mcp"),
            ("oversized", "x" * 33),
        ):
            apply(variant(f"{name}-account", native_identity=reference), failure="")
            untouched()
        foreign_name = pwd.getpwuid(fixture["foreign_identity"]["uid"]).pw_name
        apply(
            variant("foreign-account", native_identity=foreign_name),
            failure="unsafe_custody",
        )
        untouched()
        resolver_name = pwd.getpwuid(configuration["resolver_identity"]["uid"]).pw_name
        apply(
            variant("duplicate-account", native_identity=resolver_name),
            failure="distinct_service_identities_required",
        )
        untouched()
        results.append(STEP)

        STEP = "public-jwks-refusals"
        for source, modes in (
            (
                "native",
                (
                    "private",
                    "malformed",
                    "duplicate",
                    "invalid-key",
                    "redirect",
                    "oversized",
                    "unbounded",
                ),
            ),
            ("resolver", ("private", "invalid-key")),
        ):
            for mode in modes:
                replace(
                    root / "server-mode.json",
                    {"native": "valid", "resolver": "valid"} | {source: mode},
                )
                apply(failure="")
                untouched()
        replace(root / "server-mode.json", {"native": "valid", "resolver": "valid"})
        assert not (root / "public-server" / "redirect-followed").exists()
        write(
            root / "wrong-ca.pem", (root / "trust" / "issuer-ca.crt.pem").read_bytes()
        )
        apply(variant("untrusted-ca", ca_bundle=str(root / "wrong-ca.pem")), failure="")
        results.append(STEP)

        STEP = "current-nix-binding"
        template = load(configuration["native_template"])
        wrong = copy.deepcopy(template)
        wrong["resource"]["audience"] = "another-deployment"
        apply(
            template_variant("wrong-binding", wrong),
            failure="fresh_profile_binding_conflict",
        )
        wrong = copy.deepcopy(template)
        wrong["resource"]["target"] = (
            configuration["native_issuer"] + "/cc/views/personal-finance"
        )
        apply(
            template_variant("wrong-default-route", wrong),
            failure="fresh_profile_binding_conflict",
        )
        apply(
            variant(
                "redirect-origin", native_jwks_url=configuration["resolver_jwks_url"]
            ),
            failure="public_endpoint_binding_conflict",
        )
        untouched()
        results.append(STEP)

        STEP = "unsafe-input-custody"
        linked = root / "linked-config.json"
        linked.symlink_to(fixture["config"])
        apply(linked, failure="symlink_input")
        unsafe = variant("writable-config")
        unsafe.chmod(0o666)
        apply(unsafe, failure="unsafe_custody")
        unsafe.chmod(0o644)
        signer = Path(configuration["native_signing_key"])
        held = signer.with_name("held-key.pem")
        os.rename(signer, held)
        try:
            signer.symlink_to(held)
            apply(failure="symlink_input")
            signer.unlink()
            apply(failure="")
            assert not signer.exists(), "missing_signer_was_regenerated"
        finally:
            os.rename(held, signer)
        old_owner = (signer.stat().st_uid, signer.stat().st_gid)
        try:
            os.chown(
                signer,
                fixture["foreign_identity"]["uid"],
                fixture["foreign_identity"]["gid"],
            )
            apply(failure="unsafe_custody")
        finally:
            os.chown(signer, *old_owner)
        old_mode = stat.S_IMODE(signer.stat().st_mode)
        try:
            signer.chmod(0o644)
            apply(failure="unsafe_custody")
        finally:
            signer.chmod(old_mode)
        native_link = root / "native" / "linked-state.db"
        native_link.symlink_to(native_database)
        apply(
            variant("linked-state", native_oauth_database=str(native_link)),
            failure="symlink_input",
        )
        apply(
            variant(
                "incorrect-old-guess",
                native_oauth_database=str(root / "native" / "oauth-state.sqlite3"),
            ),
            failure="",
        )
        assert not (root / "native" / "oauth-state.sqlite3").exists()
        ancestor = root / "policy-link"
        ancestor.symlink_to(root / "policy", target_is_directory=True)
        apply(
            variant("linked-directory", policy_directory=str(ancestor)),
            failure="symlink_input",
        )
        (root / "policy").chmod(0o777)
        try:
            apply(failure="unsafe_custody")
        finally:
            (root / "policy").chmod(0o755)
        assert retained(configuration) == baseline
        untouched()
        results.append(STEP)

        STEP = "partial-history-refusal"
        denial = root / "native" / "denial"
        directory(denial, configuration["native_identity"])
        write(
            denial / "initialization.started",
            b"interrupted\n",
            mode=0o600,
            identity=configuration["native_identity"],
        )
        partial = fingerprint(denial / "initialization.started")
        apply(failure="partial_deny_history")
        assert fingerprint(denial / "initialization.started") == partial
        (denial / "initialization.started").unlink()
        denial.rmdir()
        wrong_profile = {
            "resource": template["resource"],
            "cutover_at": int(time.time()) - 100,
            "legacy_refresh_until": int(time.time()) + 100,
            "legacy_mappings": [],
        }
        write(root / "policy" / "native-profile.json", wrong_profile, mode=0o400)
        apply(failure="fresh_profile_binding_conflict")
        assert load(root / "policy" / "native-profile.json") == wrong_profile
        (root / "policy" / "native-profile.json").unlink()
        results.append(STEP)

        STEP = "missing-native-history-schema"
        schema_inventory = (
            "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
        )
        faults = [
            (table, f"DROP TABLE {table}")
            for table in (
                "consumed_refresh",
                "oauth_client",
                "refresh_token",
                "revoked_refresh_family",
            )
        ] + [("consumed-column", "ALTER TABLE consumed_refresh DROP COLUMN client_id")]
        for name, mutation in faults:
            damaged = root / "native" / f"missing-{name}.db"
            clone_database(native_database, damaged, configuration["native_identity"])
            change(damaged, mutation)
            inventory = query(damaged, schema_inventory)
            unchanged = fingerprint(damaged)
            damaged_config = variant(
                f"missing-history-{name}", native_oauth_database=str(damaged)
            )
            invoke(damaged_config, failure="native_oauth_history_schema_mismatch")
            apply(damaged_config, failure="native_oauth_history_schema_mismatch")
            assert query(damaged, schema_inventory) == inventory, (
                "native_schema_was_recreated"
            )
            assert fingerprint(damaged) == unchanged, "native_history_was_rewritten"
            assert not (root / "policy" / "native-adoption.approved").exists()
            untouched()
        results.append(STEP)

        STEP = "failed-grant-append-no-approval"
        failed_policy = root / "failed-policy"
        directory(failed_policy)
        failed_template = copy.deepcopy(template)
        failed_template["deny"]["state_directory"] = str(
            root / "native" / "failed-denial"
        )
        bad_grants = load(configuration["finance_grants"])
        bad_grants["grants"][1]["subject"] = "synthetic-unenrolled"
        write(root / "failed-grants.json", bad_grants)
        failed_config = template_variant(
            "failed-append",
            failed_template,
            policy_directory=str(failed_policy),
            finance_grants=str(root / "failed-grants.json"),
        )
        apply(failed_config, failure="finance_append_failed")
        assert not (failed_policy / "native-adoption.approved").exists()
        assert (root / "native" / "failed-denial" / "owner.json").exists()
        assert query(database, "SELECT * FROM grants ORDER BY id") == ordinary
        assert retained(configuration) == baseline
        results.append(STEP)

        STEP = "fresh-preparation"
        prepared = apply(named_config)
        assert prepared["approved"] and prepared["deny_history"] == "initialize"
        assert (
            prepared["finance_grants"] == "append"
            and prepared["deny_validation"] == "verified"
        )
        assert (denial / "owner.json").stat().st_uid == configuration[
            "native_identity"
        ]["uid"]
        profile = NativeProfileSettings.model_validate_json(
            (root / "policy" / "native-profile.json").read_bytes()
        )
        assert (
            profile.cutover_at == profile.legacy_refresh_until == prepared["cutover_at"]
        )
        assert (
            profile.legacy_mappings == ()
            and profile.resource.model_dump(mode="json") == template["resource"]
        )
        for name in artifacts:
            path = root / "policy" / name
            assert (
                path.stat().st_uid == 0 and stat.S_IMODE(path.stat().st_mode) == 0o400
            )
        PublicKeys(load(root / "policy" / "native-jwks.json"))
        PublicKeys(load(root / "policy" / "resolver-jwks.json"))
        assert len(query(database, "SELECT * FROM grants")) == 4
        assert (
            query(database, "SELECT * FROM grants WHERE id=?", (ordinary[0][0],))
            == ordinary
        )
        assert retained(configuration) == baseline
        results.append(STEP)

        STEP = "resuming-completed-preparation-artifacts"
        failed_publications = {
            name: fingerprint(failed_policy / name)
            for name in artifacts
            if name != "native-adoption.approved"
        }
        failed_owner = (root / "native" / "failed-denial" / "owner.json").read_bytes()
        failed_cutover = load(failed_policy / "native-profile.json")["cutover_at"]
        replace(root / "failed-grants.json", load(configuration["finance_grants"]))
        recovered = apply(failed_config)
        assert recovered["approved"] and recovered["cutover_at"] == failed_cutover
        assert (
            recovered["finance_grants"] == "reuse"
            and recovered["deny_history"] == "reuse"
        )
        assert {
            name: fingerprint(failed_policy / name)
            for name in artifacts
            if name != "native-adoption.approved"
        } == failed_publications
        assert (
            root / "native" / "failed-denial" / "owner.json"
        ).read_bytes() == failed_owner
        assert retained(configuration) == baseline
        results.append(STEP)

        STEP = "matching-retry-preserves-history"
        successful(
            phase_command + ["populate-denial"], configuration["native_identity"]
        )
        history, clock = deny_snapshot(configuration)
        assert history[2]["generation"] == 9 and len(history[3]) == 1
        publications = {name: fingerprint(root / "policy" / name) for name in artifacts}
        grants_before = query(database, "SELECT * FROM grants ORDER BY id")
        time.sleep(1.1)
        assert invoke()["cutover_at"] == prepared["cutover_at"]
        assert deny_snapshot(configuration) == (history, clock), (
            "plan_changed_deny_clock"
        )
        repeated = apply()
        assert repeated["approved"] and repeated["finance_grants"] == "reuse"
        assert (
            repeated["deny_history"] == "reuse"
            and repeated["cutover_at"] == prepared["cutover_at"]
        )
        after, later = deny_snapshot(configuration)
        assert after == history and later >= clock
        assert {
            name: fingerprint(root / "policy" / name) for name in artifacts
        } == publications
        assert query(database, "SELECT * FROM grants ORDER BY id") == grants_before
        assert retained(configuration) == baseline
        results.append(STEP)

        STEP = "existing-original-cutover-time"
        resumed_policy = root / "resumed-policy"
        directory(resumed_policy)
        old_cutover = int(time.time()) - 3600
        old_profile = profile.model_dump(mode="json") | {
            "cutover_at": old_cutover,
            "legacy_refresh_until": old_cutover,
        }
        write(resumed_policy / "native-profile.json", old_profile, mode=0o400)
        original_profile = fingerprint(resumed_policy / "native-profile.json")
        resumed = variant("resumed", policy_directory=str(resumed_policy))
        assert apply(resumed)["cutover_at"] == old_cutover
        assert fingerprint(resumed_policy / "native-profile.json") == original_profile
        assert retained(configuration) == baseline
        results.append(STEP)

        STEP = "existing-public-conflicts"
        replace(
            root / "server-mode.json", {"native": "changed-key", "resolver": "valid"}
        )
        apply(failure="retained_signer_mismatch")
        replace(root / "server-mode.json", {"native": "valid", "resolver": "valid"})
        bad_receipt = load(root / "policy" / "native-adoption.approved") | {
            "deny_installation": "0" * 32
        }
        with edited(root / "policy" / "native-adoption.approved", bad_receipt):
            apply(failure="approval_conflict")
        for name in (
            "native-profile.json",
            "native-jwks.json",
            "native-adoption.approved",
        ):
            with edited(root / "policy" / name, None):
                apply(failure="invalid_existing_artifact")
        private_keys = load(root / "policy" / "native-jwks.json")
        private_keys["keys"][0]["d"] = "DO-NOT-LOG-PRIVATE-FIELD"
        with edited(root / "policy" / "native-jwks.json", private_keys):
            apply(failure="existing_public_artifact_conflict")
        missing_policy = root / "lone-approval"
        directory(missing_policy)
        write(
            missing_policy / "native-adoption.approved",
            load(root / "policy" / "native-adoption.approved"),
            mode=0o400,
        )
        apply(
            variant("lone-approval-config", policy_directory=str(missing_policy)),
            failure="approval_conflict",
        )
        assert sorted(path.name for path in missing_policy.iterdir()) == [
            "native-adoption.approved"
        ]
        path = root / "policy" / "native-profile.json"
        os.chown(
            path, fixture["foreign_identity"]["uid"], fixture["foreign_identity"]["gid"]
        )
        try:
            apply(failure="unsafe_custody")
        finally:
            os.chown(path, 0, 0)
        results.append(STEP)

        STEP = "partial-and-mismatched-grants"
        grant_id = load(configuration["finance_grants"])["grants"][0]["id"]
        for column, value in (("active", 0), ("max_lifetime_seconds", 901)):
            original = query(
                database, f"SELECT {column} FROM grants WHERE id=?", (grant_id,)
            )[0][0]
            change(
                database, f"UPDATE grants SET {column}=? WHERE id=?", (value, grant_id)
            )
            try:
                apply(failure="")
                assert query(
                    database, f"SELECT {column} FROM grants WHERE id=?", (grant_id,)
                ) == [(value,)]
            finally:
                change(
                    database,
                    f"UPDATE grants SET {column}=? WHERE id=?",
                    (original, grant_id),
                )
        change(
            database,
            "UPDATE grants SET id=? WHERE id=?",
            (grant_id + ".held", grant_id),
        )
        try:
            apply(failure="partial_finance_grants")
            assert query(
                database, "SELECT count(*) FROM grants WHERE id=?", (grant_id,)
            ) == [(0,)]
        finally:
            change(
                database,
                "UPDATE grants SET id=? WHERE id=?",
                (grant_id, grant_id + ".held"),
            )
        assert query(database, "SELECT * FROM grants ORDER BY id") == grants_before
        results.append(STEP)

        STEP = "retained-deny-conflicts"
        owner = denial / "owner.json"
        with edited(owner, load(owner) | {"binding": "0" * 64}):
            apply(failure="deny_binding_conflict")
        held_owner = root / "native" / "held-owner.json"
        os.rename(owner, held_owner)
        try:
            apply(failure="partial_deny_history")
            assert not owner.exists()
        finally:
            os.rename(held_owner, owner)
        deny_db = denial / "denial.sqlite"
        original = query(deny_db, "SELECT document FROM snapshot")[0][0]
        damaged = json.loads(original)
        damaged["document"] = "invalid-synthetic-signature"
        change(deny_db, "UPDATE snapshot SET document=?", (json.dumps(damaged),))
        signature_policy = root / "signature-policy"
        directory(signature_policy)
        try:
            apply(
                variant(
                    "invalid-deny-signature", policy_directory=str(signature_policy)
                ),
                failure="deny_validation_failed",
            )
            assert not (signature_policy / "native-adoption.approved").exists()
            assert (
                json.loads(query(deny_db, "SELECT document FROM snapshot")[0][0])
                == damaged
            )
        finally:
            change(deny_db, "UPDATE snapshot SET document=?", (original,))
        after, _ = deny_snapshot(configuration)
        assert after == history
        results.append(STEP)

        STEP = "retained-native-adoption-conflict"
        cloned = root / "native" / "conflicting-state.db"
        clone_database(native_database, cloned, configuration["native_identity"])
        change(
            cloned,
            "INSERT INTO native_deny_adoption VALUES (1,?,?)",
            ("0" * 64, "0" * 32),
        )
        apply(
            variant("lost-native-history", native_oauth_database=str(cloned)),
            failure="retained_deny_history_missing",
        )
        change(cloned, "DELETE FROM native_deny_adoption")
        change(
            cloned,
            "INSERT INTO native_profile_cutover VALUES (1,1,?,?,?,?)",
            (
                configuration["native_issuer"],
                profile.cutover_at - 1,
                profile.cutover_at - 1,
                json.dumps(template["resource"]),
            ),
        )
        apply(
            variant("changed-native-cutover", native_oauth_database=str(cloned)),
            failure="retained_cutover_conflict",
        )
        assert retained(configuration) == baseline
        results.append(STEP)
        assert apply()["approved"]
        assert retained(configuration) == baseline
        assert {path.name for path in (root / "trust").iterdir()} == trust_members
        successful(
            resolver + ["tls", "--plan", configuration["tls_plan"], "status"],
            configuration["trust_identity"],
        )
        STEP = "retained-replay-after-reopen"
        write(
            root / "native" / "check-replay",
            b"check\n",
            mode=0o600,
            identity=configuration["native_identity"],
        )
        wait_for(lambda: (root / "native" / "replay-preserved").exists(), native)
        assert query(
            native_database, "SELECT count(*) FROM revoked_refresh_family"
        ) == [(1,)]
        assert query(native_database, "SELECT count(*) FROM refresh_token") == [(0,)]
        results.append(STEP)
        print(
            json.dumps(
                {
                    "kind": "atrium.native-cutover-fixture",
                    "passed": results,
                    "native_oauth_history_preserved": True,
                    "signers_rotated": False,
                    "replay_revokes_successor_after_reopen": True,
                    "real_policy_and_deny_implementations": True,
                    "production_operations": False,
                },
                sort_keys=True,
            )
        )
    finally:
        for process in (server, native):
            if process is not None:
                process.terminate()
                process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument(
        "--phase", choices=("native-history", "public-server", "populate-denial")
    )
    args = parser.parse_args()
    fixture = load(args.fixture)
    configuration = load(fixture["config"])
    if args.phase == "native-history":
        native_history(configuration)
    elif args.phase == "public-server":
        serve_public_keys(fixture, configuration)
    elif args.phase == "populate-denial":
        populate_denial(configuration)
    else:
        try:
            tests(args.fixture, fixture, configuration)
        except (
            AssertionError,
            OSError,
            ValueError,
            KeyError,
            TypeError,
            sqlite3.Error,
            subprocess.TimeoutExpired,
        ) as error:
            print(
                json.dumps(
                    {
                        "stage": STEP,
                        "exception_type": type(error).__name__,
                        "frames": [
                            {
                                "file": Path(frame.filename).name,
                                "line": frame.lineno,
                                "function": frame.name,
                            }
                            for frame in traceback.extract_tb(error.__traceback__)[-4:]
                        ],
                    },
                    sort_keys=True,
                ),
                file=sys.stderr,
            )
            raise SystemExit("atrium_native_cutover_fixture_failed:" + STEP) from None


if __name__ == "__main__":
    main()
