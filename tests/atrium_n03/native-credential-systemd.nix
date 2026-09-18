{ pkgs, resolverPackage, nativePackage, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  ids = import ../../lib/service-uids.nix { };
  resolverPython = pkgs.python312.withPackages (ps: [ (ps.toPythonModule resolverPackage) ]);
  nativePython = pkgs.python313.withPackages (ps: [ (ps.toPythonModule nativePackage) ]);
  trust = "/run/atrium-native-credential-fixture-trust";
  fixtureSources = lib.mapAttrs (_: path: "${trust}/${builtins.baseNameOf path}");
  sources = {
    atrium-native-policy = fixtureSources runtime.policyCredentials;
    homelab-mcp = fixtureSources runtime.nativeCredentials;
    atrium-native-settings = fixtureSources
      (lib.getAttrs [ "native-profile" "resolver-client-cert" ] runtime.nativeCredentials);
  };
  policyTemplate = runtime.nativePolicyTemplate // {
    authorities = [{
      id = "fixture";
      issuer = "https://identity.atrium.invalid";
      audience = "https://resolver.atrium.invalid";
      jwks_uri = "https://identity.atrium.invalid/jwks";
    }];
    group_authority = "fixture";
    state_directory = "/run/atrium-native-policy-fixture/state";
    policy_path = "/run/atrium-native-policy-fixture/policy.json";
    signing = {
      issuer = "https://resolver.atrium.invalid";
      directory = "/run/atrium-native-policy-fixture/signing";
    };
    isolated_harness = true;
    native_policy = runtime.nativePolicyTemplate.native_policy // {
      adapters = [{
        id = "homelab-mcp";
        native_issuer = "https://native.atrium.invalid";
        deployment = "home-mcp";
        authorities.fixture = "mcp";
        views = [ "fixture-view" ];
        certificates = [ ];
      }];
    };
  };
  nativeTemplate = runtime.native // {
    resource = {
      id = "fixture-view";
      domain = "personal:fixture";
      audience = "home-mcp";
      target = "https://native.atrium.invalid/mcp";
    };
    issuance = runtime.native.issuance // {
      resolver_issuer = "https://resolver.atrium.invalid";
    };
    policy = runtime.native.policy // {
      authority = "fixture";
      resolver_issuer = "https://resolver.atrium.invalid";
    };
    deny = runtime.native.deny // {
      issuer = "https://resolver.atrium.invalid";
      feed_url = "https://127.0.0.1:1/v1/deny-feed";
      jwks_url = "https://127.0.0.1:1/.well-known/jwks.json";
      state_directory = "/run/homelab-mcp-fixture/denial";
    };
  };
  policyFile = pkgs.writeText "native-policy-custody-template.json" (builtins.toJSON policyTemplate);
  nativeFile = pkgs.writeText "native-custody-template.json" (builtins.toJSON nativeTemplate);
  renderer = "${resolverPython}/bin/python -I -B ${../../hosts/forge/atrium/runtime-bindings.py}";
  settingsCommand = "${renderer} native-environment --template ${nativeFile} --profile ${projection.path "atrium-native-settings" "native-profile"} --client-certificate ${projection.path "atrium-native-settings" "resolver-client-cert"} --output /run/atrium-native-mcp/native.env";
  program = pkgs.writeText "atrium-native-credential-systemd-fixture.py" ''
    import argparse
    import importlib.util
    import json
    import os
    import shlex
    import ssl
    import stat
    import subprocess
    from datetime import UTC, datetime
    from pathlib import Path

    TRUST = Path("${trust}")
    SOURCES = json.loads(${builtins.toJSON (builtins.toJSON sources)})
    POLICY = json.loads(${builtins.toJSON (builtins.toJSON policyTemplate)})
    NATIVE = json.loads(${builtins.toJSON (builtins.toJSON nativeTemplate)})
    PLAN = json.loads(${builtins.toJSON (builtins.toJSON runtime.tlsPlan)})
    SETTINGS_COMMAND = shlex.split(${builtins.toJSON settingsCommand})
    CA_BUNDLE_MAX_BYTES = 1024 * 1024
    CA_BUNDLE_FIXTURE_BYTES = 464268

    def host_module(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def projector():
        return host_module("projection", "${../../hosts/forge/atrium/credential-projection.py}")

    def bindings():
        return host_module("bindings", "${../../hosts/forge/atrium/runtime-bindings.py}")

    def write_new(path, contents, mode=0o600):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())

    def replace(path, contents):
        pending = path.with_name(".replacement")
        try:
            write_new(pending, contents, 0o400)
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)

    def receipt(unit, name, values):
        write_new(Path(f"/run/{unit}-fixture/{name}.json"), json.dumps(values).encode())

    def initialize():
        from atrium_profiles.crypto import public_jwk
        from atrium_resolver.tls_bootstrap import TLSBootstrapPlan, initialize_tls
        from cryptography import x509

        now = int(datetime.now(UTC).timestamp())
        PLAN["directory"] = str(TRUST)
        for entry in PLAN["authorities"] + PLAN["certificates"]:
            entry["common_name"] = "Synthetic " + entry["id"]
            if entry.get("purpose") == "server":
                entry["names"] = ["127.0.0.1"]
        initialize_tls(TLSBootstrapPlan.model_validate_json(json.dumps(PLAN)), now=now)
        ca = x509.load_pem_x509_certificate((TRUST / "issuer-ca.crt.pem").read_bytes())
        write_new(TRUST / "resolver-jwks.json", json.dumps({
            "keys": [public_jwk(ca.public_key(), "fixture-resolver")]
        }).encode())
        pem = (TRUST / "native-ca.crt.pem").read_bytes()
        # Match the parent's metadata-only size measurement, not live CA bytes.
        annotated = b"# Synthetic CA label: \xc5\x81\xc3\xb3d\xc5\xba\n" + pem
        bundle = (annotated * (CA_BUNDLE_FIXTURE_BYTES // len(annotated))).ljust(
            CA_BUNDLE_FIXTURE_BYTES, b"\n"
        )
        assert 65536 < len(bundle) < CA_BUNDLE_MAX_BYTES
        assert any(value > 127 for value in bundle)
        write_new(TRUST / "ca-certificates.crt", bundle)
        profile = json.dumps({
            "resource": NATIVE["resource"], "cutover_at": now,
            "legacy_refresh_until": now + 3600, "legacy_mappings": [],
        }).encode()
        write_new(TRUST / "native-profile.json", profile.ljust(65537, b" "))

    def policy_tls(directory=None):
        from atrium_resolver.config import Settings
        from atrium_resolver.native_policy_tls import native_policy_server_config

        if directory is None:
            settings = Settings.model_validate_json(
                Path("/run/atrium-native-policy/settings.json").read_bytes()
            )
        else:
            document = json.loads(json.dumps(POLICY))
            material = document["native_policy"]
            for field, name in (
                ("server_certificate_path", "policy-server-cert"),
                ("server_private_key_path", "policy-server-key"),
                ("client_ca_path", "policy-client-ca"),
            ):
                material[field] = str(directory / name)
            material["adapters"][0]["certificates"] = [
                bindings().fingerprint(directory / "policy-client-cert")
            ]
            settings = Settings.model_validate_json(json.dumps(document))
        return native_policy_server_config(settings, port=0)

    def native_client(directory=None):
        from homelab_mcp.native_policy_client import NativePolicyClient, NativePolicyClientSettings

        if directory is None:
            settings = NativePolicyClientSettings.model_validate_json(
                os.environ["HOMELAB_MCP_ATRIUM_POLICY"]
            )
        else:
            document = dict(NATIVE["policy"])
            for field, name in (
                ("resolver_jwks", "resolver-jwks"),
                ("ca_certificate_path", "policy-ca"),
                ("client_certificate_path", "policy-client-cert"),
                ("client_private_key_path", "policy-client-key"),
            ):
                document[field] = str(directory / name)
            settings = NativePolicyClientSettings.model_validate_json(json.dumps(document))
        return NativePolicyClient(
            settings, native_issuer="https://native.atrium.invalid",
            upstream_issuer="https://identity.atrium.invalid",
            observe_clock=lambda: int(datetime.now(UTC).timestamp()),
        )

    def native_tls(directory=None):
        from homelab_mcp.issuance_config import ResolverIssuanceSettings
        from homelab_mcp.mtls import ResolverTLSSettings, tls_server_config
        from starlette.applications import Starlette

        if directory is None:
            tls = ResolverIssuanceSettings.model_validate_json(
                os.environ["HOMELAB_MCP_ATRIUM_ISSUANCE"]
            ).tls
        else:
            document = dict(NATIVE["issuance"]["tls"])
            for field, name in (
                ("server_certificate", "server-cert"),
                ("server_private_key", "server-key"),
                ("client_ca", "resolver-client-ca"),
            ):
                document[field] = str(directory / name)
            document["resolver_certificates"] = [
                bindings().fingerprint(directory / "resolver-client-cert")
            ]
            tls = ResolverTLSSettings.model_validate_json(json.dumps(document))
        # Only the real native TLS loader is exercised, not an OAuth/MCP request.
        return tls_server_config(Starlette(), host="127.0.0.1", port=0, tls=tls)

    def deny_tls(directory=None):
        import asyncio

        from homelab_mcp.deny_admission import MAX_CA_BUNDLE_BYTES, NativeDenial
        from homelab_mcp.deny_config import NativeDenySettings
        from homelab_mcp.deny_store import MAX_DOCUMENT_BYTES, DenyStore

        assert MAX_CA_BUNDLE_BYTES == CA_BUNDLE_MAX_BYTES
        assert MAX_DOCUMENT_BYTES == 65536
        if directory is None:
            document = json.loads(os.environ["HOMELAB_MCP_ATRIUM_DENY"])
        else:
            document = dict(NATIVE["deny"])
            document["ca_bundle"] = str(directory / "public-ca")
            document["state_directory"] = "/run/homelab-mcp-fixture/raw-denial"
        settings = NativeDenySettings.model_validate_json(json.dumps(document))
        assert settings.feed_url == "https://127.0.0.1:1/v1/deny-feed"
        assert settings.jwks_url == "https://127.0.0.1:1/.well-known/jwks.json"
        assert settings.state_directory in (
            Path("/run/homelab-mcp-fixture/denial"),
            Path("/run/homelab-mcp-fixture/raw-denial"),
        )
        store = DenyStore(settings, binding=settings.binding("https://native.atrium.invalid"))
        denial = NativeDenial(settings, store)

        async def load():
            try:
                # The real startup loads its configured CA budget, then polls
                # a closed guest-loopback port. No reader or transport is mocked.
                await denial.start()
                assert denial.last_error == "native_deny_transport_unavailable"
                context = denial._client._transport._pool._ssl_context
                assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
                assert context.minimum_version == ssl.TLSVersion.TLSv1_2
                assert context.cert_store_stats()["x509_ca"] > 0
                return context
            finally:
                await denial.close()

        return asyncio.run(load())

    def reproduce(unit):
        from atrium_profiles import ProfileError

        module = projector()
        directory = Path(f"/run/credentials/{unit}.service")
        for path, is_directory in [(directory, True)] + [
            (directory / name, False) for name in SOURCES[unit]
        ]:
            descriptor = os.open(path, module.DIRECTORY_FLAGS if is_directory else os.O_RDONLY | os.O_NOFOLLOW)
            try:
                module.source_metadata(descriptor, directory=is_directory)
                assert os.fstat(descriptor).st_uid == 0
                assert stat.S_IMODE(os.fstat(descriptor).st_mode) == (0o550 if is_directory else 0o440)
                assert os.fstatvfs(descriptor).f_flag & os.ST_RDONLY
            finally:
                os.close(descriptor)
        attempts = []
        if unit == "atrium-native-policy":
            attempts = [lambda: policy_tls(directory)]
        elif unit == "homelab-mcp":
            from homelab_mcp.deny_store import read_private

            attempts = [
                lambda: native_client(directory), lambda: native_tls(directory),
                lambda: deny_tls(directory),
                lambda: read_private(directory / "resolver-jwks", 65536),
            ]
        for call in attempts:
            try:
                call()
            except ProfileError as error:
                assert error.code == "insecure_runtime_directory"
            else:
                raise AssertionError("actual native reader accepted root-owned systemd custody")
        receipt(unit, "reproduction", {
            "actual_LoadCredential": True, "exact_root_acl_and_read_only_mount": True,
            "direct_reader_refusals": len(attempts),
            # The renderer uses ordinary reads; its new projection is consistency,
            # not a claim that its old raw reads failed service-ownership checks.
            "renderer_only": unit == "atrium-native-settings",
        })

    def rendered_environment():
        return dict(value.split("=", 1) for value in shlex.split(
            Path("/run/atrium-native-mcp/native.env").read_text()
        ))

    def permit(unit):
        from atrium_profiles.runtime import private_directory, private_open

        directory = Path(f"/run/{unit}-credentials/material")
        module = projector()
        private_directory(directory, create=False)
        assert set(os.listdir(directory)) == set(SOURCES[unit])
        for name in SOURCES[unit]:
            descriptor = private_open(directory / name, os.O_RDONLY)
            try:
                module.private_metadata(descriptor, directory=False)
            finally:
                os.close(descriptor)
            assert (directory / name).read_bytes() == Path(
                f"/run/credentials/{unit}.service/{name}"
            ).read_bytes()
        if unit == "atrium-native-policy":
            config = policy_tls()
            assert config.ssl.verify_mode == ssl.CERT_REQUIRED
            assert config.ssl.minimum_version == ssl.TLSVersion.TLSv1_2
            assert not config.proxy_headers and config.host == "127.0.0.1"
            document = json.loads(Path("/run/atrium-native-policy/settings.json").read_bytes())
            assert document["native_policy"]["adapters"][0]["certificates"] == [
                bindings().fingerprint(directory / "policy-client-cert")
            ]
        else:
            from homelab_mcp.native_profile import NativeProfileSettings

            environment = rendered_environment()
            profile = NativeProfileSettings.model_validate_json(environment["HOMELAB_MCP_ATRIUM_NATIVE"])
            assert profile.resource.model_dump(mode="json") == NATIVE["resource"]
            assert profile.legacy_mappings == ()
            assert (directory / "native-profile").stat().st_size == 65537
            if unit == "homelab-mcp":
                import asyncio

                from atrium_profiles import PublicKeys
                from homelab_mcp.deny_store import MAX_DOCUMENT_BYTES, DenyAdmissionError, read_private

                assert all(os.environ[name] == value for name, value in environment.items())
                client = native_client()
                try:
                    context = client._client._transport._pool._ssl_context
                    assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
                    assert context.minimum_version == ssl.TLSVersion.TLSv1_2
                finally:
                    asyncio.run(client.close())
                config = native_tls()
                assert config.ssl.verify_mode == ssl.CERT_OPTIONAL
                assert config.ssl.minimum_version == ssl.TLSVersion.TLSv1_2
                assert not config.proxy_headers
                keys = PublicKeys(json.loads(read_private(directory / "resolver-jwks", 65536)))
                assert keys.key("fixture-resolver").key_size == 2048
                assert MAX_DOCUMENT_BYTES == 65536
                try:
                    read_private(directory / "public-ca", MAX_DOCUMENT_BYTES)
                except DenyAdmissionError as error:
                    assert error.code == "native_deny_state_invalid"
                else:
                    raise AssertionError("native document budget unexpectedly widened")
                assert (directory / "public-ca").stat().st_size == CA_BUNDLE_FIXTURE_BYTES
                deny_tls()
        receipt(unit, "permit", {
            "exact_source_bytes": True, "private_projection_accepted": True,
            "unchanged_application_loaders": unit != "atrium-native-settings",
            "actual_renderer": unit != "homelab-mcp",
            "uid": os.geteuid(),
        })

    def custody(unit, fault):
        from atrium_profiles import ProfileError

        directory = Path(f"/run/{unit}-credentials/material")
        name = {
            "atrium-native-policy": "policy-server-key",
            "homelab-mcp": "policy-client-key",
            "atrium-native-settings": "native-profile",
        }[unit]
        path = directory / name
        module = projector()
        if unit == "atrium-native-settings" or fault == "link":
            try:
                for item, is_directory in ((directory, True), (path, False)):
                    descriptor = os.open(item, module.DIRECTORY_FLAGS if is_directory else os.O_RDONLY | os.O_NOFOLLOW)
                    try:
                        module.private_metadata(descriptor, directory=is_directory)
                    finally:
                        os.close(descriptor)
            except (ValueError, OSError):
                pass
            else:
                raise AssertionError("projector accepted tampered private custody")
            if unit != "homelab-mcp":
                return
        try:
            if unit == "homelab-mcp":
                from homelab_mcp.deny_store import DenyAdmissionError, read_private

                try:
                    read_private(path, 65536)
                except DenyAdmissionError:
                    assert fault == "link"
                    return
            else:
                from atrium_resolver.device_certificates import read_material

                read_material(path)
        except (ProfileError, OSError):
            return
        raise AssertionError("actual native reader accepted tampered private custody")

    def wrong_key(unit, role):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import rsa

        directory = Path(f"/run/{unit}-credentials/material")
        name = "policy-server-key" if unit == "atrium-native-policy" else (
            "policy-client-key" if role == "client" else "server-key"
        )
        path = directory / name
        original = path.read_bytes()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        try:
            replace(path, key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ))
            try:
                if unit == "atrium-native-policy":
                    policy_tls()
                elif role == "client":
                    native_client()
                else:
                    native_tls()
            except ssl.SSLError as error:
                assert error.reason == "KEY_VALUES_MISMATCH"
            else:
                raise AssertionError("actual native TLS loader accepted a mismatched key")
        finally:
            replace(path, original)

    def renderer_case(fault):
        directory = Path("/run/atrium-native-settings-credentials/material")
        path = directory / ("resolver-client-cert" if fault == "certificate" else "native-profile")
        output = Path("/run/atrium-native-mcp/native.env")
        original, rendered = path.read_bytes(), output.read_bytes()
        try:
            if fault == "certificate":
                contents = b"not a certificate"
            elif fault == "profile":
                profile = json.loads(original)
                profile["resource"]["target"] = "https://wrong.atrium.invalid/mcp"
                contents = json.dumps(profile).encode()
            else:
                assert fault in ("maximum", "oversize")
                contents = original.rstrip().ljust(1024 * 1024 + (fault == "oversize"), b" ")
            replace(path, contents)
            result = subprocess.run(SETTINGS_COMMAND, capture_output=True)
            if fault == "maximum":
                assert result.returncode == 0 and not result.stdout and not result.stderr
            else:
                assert result.returncode != 0 and not result.stdout
                assert result.stderr == b"atrium_runtime_bindings_rejected\n"
            assert output.read_bytes() == rendered
        finally:
            replace(path, original)

    def selections(unit):
        module = projector()
        names = sorted(SOURCES[unit])
        for selected in (
            names[:-1], names + [names[0]], names + ["environment"],
            ["management", "personal-anthropic", "family-anthropic"],
        ):
            try:
                module.project(unit, selected)
            except ValueError as error:
                assert str(error) == "invalid credential selection"
            else:
                raise AssertionError("unexpected native credential selection accepted")

    def bundle_loader_bounds():
        from homelab_mcp.deny_store import DenyAdmissionError

        path = Path("/run/homelab-mcp-credentials/material/public-ca")
        original = path.read_bytes()
        try:
            replace(path, original.ljust(CA_BUNDLE_MAX_BYTES, b"\n"))
            assert path.stat().st_size == CA_BUNDLE_MAX_BYTES
            deny_tls()
            replace(path, original.ljust(CA_BUNDLE_MAX_BYTES + 1, b"\n"))
            try:
                deny_tls()
            except DenyAdmissionError as error:
                assert error.code == "native_deny_state_invalid"
            else:
                raise AssertionError("oversized CA bundle accepted")
            public_bundle = Path("${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt")
            public_bytes = public_bundle.read_bytes()
            assert len(public_bytes) <= CA_BUNDLE_MAX_BYTES
            assert any(value > 127 for value in public_bytes)
            assert b"-----BEGIN TRUSTED CERTIFICATE-----" in public_bytes
            replace(path, public_bytes)
            actual = deny_tls()
            expected = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            expected.load_verify_locations(cafile=str(public_bundle))
            assert set(actual.get_ca_certs(binary_form=True)) == set(expected.get_ca_certs(binary_form=True))
        finally:
            replace(path, original)

    def input_fault(unit, fault):
        name, limit = {
            "atrium-native-policy": ("policy-server-key", 32768),
            "homelab-mcp": ("server-key", 32768),
            "atrium-native-settings": ("resolver-client-cert", 32768),
        }[unit]
        path = Path(SOURCES[unit][name])
        saved = path.with_name(path.name + ".saved")
        if fault == "restore":
            path.unlink()
            os.rename(saved, path)
        else:
            os.rename(path, saved)
            write_new(path, b"" if fault == "empty" else b"x" * (limit + 1))

    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=(
        "initialize", "reproduce", "permit", "custody", "wrong-key",
        "renderer", "selections", "bundle-loader", "input", "failed-cleanup",
    ))
    parser.add_argument("unit", nargs="?", choices=tuple(SOURCES))
    parser.add_argument("fault", nargs="?", choices=(
        "custody", "link", "client", "server", "profile", "certificate",
        "maximum", "oversize", "empty", "restore",
    ))
    args = parser.parse_args()
    try:
        if args.phase == "initialize":
            initialize()
        elif args.phase == "reproduce":
            reproduce(args.unit)
        elif args.phase == "permit":
            permit(args.unit)
        elif args.phase == "custody":
            custody(args.unit, args.fault)
        elif args.phase == "wrong-key":
            wrong_key(args.unit, args.fault)
        elif args.phase == "renderer":
            renderer_case(args.fault)
        elif args.phase == "selections":
            selections(args.unit)
        elif args.phase == "bundle-loader":
            assert args.unit == "homelab-mcp"
            bundle_loader_bounds()
        elif args.phase == "input":
            input_fault(args.unit, args.fault)
        elif os.environ.get("SERVICE_RESULT") != "success":
            root = Path(f"/run/{args.unit}-credentials")
            assert not (root / ".pending").exists()
            assert not (root / "material").exists()
    except Exception as error:
        raise SystemExit("atrium_native_credential_fixture_" + args.phase + "_" + type(error).__name__) from None
  '';
  command = unit:
    "${if unit == "homelab-mcp" || unit == "atrium-native-settings" then nativePython else resolverPython}/bin/python -I -B ${program}";
  service = unit:
    let
      projected = projection.serviceConfig { inherit pkgs unit; credentials = sources.${unit}; };
      policy = unit == "atrium-native-policy";
      settings = unit == "atrium-native-settings";
      user = if policy then "atrium-resolver" else "homelab-mcp";
    in
    {
      partOf = lib.optional settings "homelab-mcp.service";
      requires = [ "atrium-native-credential-fixture-trust.service" ]
        ++ lib.optionals (unit == "homelab-mcp")
        [ "atrium-native-settings.service" "atrium-native-policy.service" ];
      after = [ "atrium-native-credential-fixture-trust.service" ]
        ++ lib.optionals (unit == "homelab-mcp")
        [ "atrium-native-settings.service" "atrium-native-policy.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = projected // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        RuntimeDirectory = [ projected.RuntimeDirectory "${unit}-fixture" ]
          ++ lib.optional policy "atrium-native-policy"
          ++ lib.optional settings "atrium-native-mcp";
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") sources.${unit};
        ExecStartPre = [ "${command unit} reproduce ${unit}" ] ++ projected.ExecStartPre
          ++ lib.optional policy
          "${renderer} native-policy --template ${policyFile} --client-certificate ${projection.path unit "policy-client-cert"} --output /run/atrium-native-policy/settings.json";
        ExecStart = if settings then settingsCommand else "${command unit} permit ${unit}";
        ExecStartPost = lib.optional settings "${command unit} permit ${unit}";
        ExecStopPost = "${command unit} failed-cleanup ${unit}";
        TimeoutStartSec = 60;
        MemoryMax = "256M";
        TasksMax = 64;
        LimitCORE = 0;
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        UnsetEnvironment = [ "SSLKEYLOGFILE" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" ];
        StandardOutput = "null";
      } // lib.optionalAttrs (unit == "homelab-mcp") {
        EnvironmentFile = "/run/atrium-native-mcp/native.env";
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };
in
hostPkgs.testers.runNixOSTest {
  name = "atrium-native-credential-projection";
  globalTimeout = 300;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = {
      memorySize = 1024;
      cores = 1;
      vlans = [ ];
    };
    networking.hostName = "atrium-native-credential-fixture";
    networking.useDHCP = false;
    users.groups.atrium-resolver.gid = ids.atrium-resolver.gid;
    users.groups.atrium-trust.gid = ids.atrium-trust.gid;
    users.users.atrium-resolver = {
      isSystemUser = true;
      uid = ids.atrium-resolver.uid;
      group = "atrium-resolver";
    };
    users.users.atrium-trust = {
      isSystemUser = true;
      uid = ids.atrium-trust.uid;
      group = "atrium-trust";
    };
    users.groups.homelab-mcp = { };
    users.users.homelab-mcp = {
      isSystemUser = true;
      group = "homelab-mcp";
    };
    environment.systemPackages = [ pkgs.util-linux ];
    systemd.services = {
      atrium-native-policy = service "atrium-native-policy";
      atrium-native-settings = service "atrium-native-settings";
      homelab-mcp = service "homelab-mcp";
      atrium-native-credential-fixture-trust.serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "atrium-trust";
        Group = "atrium-trust";
        RuntimeDirectory = "atrium-native-credential-fixture-trust";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "no";
        ExecStart = "${command "atrium-native-policy"} initialize";
        PrivateNetwork = true;
        ProtectSystem = "strict";
        LimitCORE = 0;
        StandardOutput = "null";
      };
    };
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    native_uid = int(machine.succeed("id -u homelab-mcp"))
    native_gid = int(machine.succeed("id -g homelab-mcp"))
    trust_probe = "setpriv --reuid ${toString ids.atrium-trust.uid} --regid ${toString ids.atrium-trust.gid} --clear-groups -- ${command "atrium-native-policy"}"
    counts = {"sources": 0, "direct_refusals": 0, "permit": 0, "custody": 0, "tls": 0, "renderer_deny": 0, "renderer_maximum": 0, "bundle_maximum": 0, "bundle_oversize": 0, "selection": 0, "copy_deny": 0, "cleanup": 0}
    for unit, uid, gid, name, command in (
        ("atrium-native-policy", ${toString ids.atrium-resolver.uid}, ${toString ids.atrium-resolver.gid}, "policy-server-key", "${command "atrium-native-policy"}"),
        ("homelab-mcp", native_uid, native_gid, "policy-client-key", "${command "homelab-mcp"}"),
        ("atrium-native-settings", native_uid, native_gid, "native-profile", "${command "atrium-native-settings"}"),
    ):
        root = f"/run/{unit}-credentials"
        # Native TLS probes use the same systemd-parsed, renderer-produced environment.
        prefix = "set -a; . /run/atrium-native-mcp/native.env; set +a; " if unit == "homelab-mcp" else ""
        probe = prefix + f"setpriv --reuid {uid} --regid {gid} --clear-groups -- {command}"
        machine.succeed(f"systemctl start {unit}")
        reproduction = json.loads(machine.succeed(f"cat /run/{unit}-fixture/reproduction.json"))
        receipt = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
        assert reproduction["actual_LoadCredential"] and reproduction["exact_root_acl_and_read_only_mount"]
        assert receipt["exact_source_bytes"] and receipt["private_projection_accepted"] and receipt["uid"] == uid
        counts["sources"] += 1
        counts["direct_refusals"] += reproduction["direct_reader_refusals"]
        counts["permit"] += 1
        machine.succeed(f"{probe} selections {unit}")
        counts["selection"] += 4
        if unit == "homelab-mcp":
            machine.succeed(f"{probe} bundle-loader {unit}")
            counts["bundle_maximum"] += 1
            counts["bundle_oversize"] += 1
        for role in (("server",) if unit == "atrium-native-policy" else ("client", "server") if unit == "homelab-mcp" else ()):
            machine.succeed(f"{probe} wrong-key {unit} {role}")
            counts["tls"] += 1
        if unit == "atrium-native-settings":
            for fault in ("profile", "certificate", "maximum", "oversize"):
                machine.succeed(f"{probe} renderer {unit} {fault}")
                counts["renderer_maximum" if fault == "maximum" else "renderer_deny"] += 1
        for fault, mutation in (
            ("custody", f"chown ${toString ids.atrium-trust.uid}:${toString ids.atrium-trust.gid} {root}/material/{name}"),
            ("custody", f"chmod 0440 {root}/material/{name}"),
            ("custody", f"chmod 0750 {root}/material"),
            ("custody", f"mv {root}/material/{name} {root}/material/held; ln -s held {root}/material/{name}"),
            ("link", f"ln {root}/material/{name} {root}/material/linked"),
        ):
            machine.succeed(mutation)
            machine.succeed(f"{probe} custody {unit} {fault}")
            counts["custody"] += 1
            machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
            counts["cleanup"] += 1
            machine.succeed(f"systemctl start {unit}")
            repeated = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
            assert repeated == receipt
        machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
        counts["cleanup"] += 1
        for fault in ("empty", "oversize"):
            machine.succeed(f"{trust_probe} input {unit} {fault}")
            machine.fail(f"systemctl start {unit}")
            machine.succeed(f"systemctl show --value -p ExecStopPost {unit} | grep 'status=0'")
            machine.succeed(f"test ! -e {root}")
            counts["copy_deny"] += 1
            counts["cleanup"] += 1
            machine.succeed(f"{trust_probe} input {unit} restore")
        machine.succeed(f"systemctl start {unit}; systemctl stop {unit}; test ! -e {root}")
        if unit == "homelab-mcp":
            machine.succeed("systemctl stop atrium-native-settings atrium-native-policy")
            machine.succeed("test ! -e /run/atrium-native-mcp; test ! -e /run/atrium-native-policy")
    machine.succeed("systemctl stop atrium-native-credential-fixture-trust")
    machine.succeed("test ! -e ${trust}")
    assert counts == {"sources": 3, "direct_refusals": 5, "permit": 3, "custody": 15, "tls": 3, "renderer_deny": 3, "renderer_maximum": 1, "bundle_maximum": 1, "bundle_oversize": 1, "selection": 12, "copy_deny": 6, "cleanup": 24}
    print(json.dumps({
        "kind": "atrium.native-credential-systemd", "counts": counts,
        "actual_systemd_LoadCredential": True, "private_keys_confined_to_guest_run": True,
        "application_tls_loaders_unchanged": True, "native_resource_requests": False,
        "deny_poll_target": "isolated-unused-loopback-port-1",
        "ca_bundle_fixture_bytes": 464268,
        "ca_bundle_contains_non_ascii_annotations": True,
        "public_nss_bundle_trusted_certificates_preserved": True,
        "selected_application_deny_ca_loader_exercised": True,
        "full_native_policy_gate": False, "live_operations": False,
    }, sort_keys=True))
  '';
}
