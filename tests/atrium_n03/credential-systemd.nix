{ pkgs, resolverPackage, controllerPackage, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  ids = import ../../lib/service-uids.nix { };
  python = pkgs.python312.withPackages (ps: [
    (ps.toPythonModule resolverPackage)
    (ps.toPythonModule controllerPackage)
  ]);
  trust = "/run/atrium-credential-fixture-trust";
  sources = {
    device-ca = "${trust}/device-ca.crt.pem";
    device-ca-key = "${trust}/device-ca.key.pem";
    registration-cert = "${trust}/registration-server.crt.pem";
    registration-key = "${trust}/registration-server.key.pem";
  };
  optionalSources = {
    native-ca = "${trust}/native-ca.crt.pem";
    native-client-cert = "${trust}/resolver-client.crt.pem";
    native-client-key = "${trust}/resolver-client.key.pem";
    native-jwks = "${trust}/native-jwks";
    model-management = "${trust}/model-management";
  };
  modelSources = {
    atrium-model-resolver-initialize = {
      inherit (optionalSources) model-management;
    };
    atrium-model-controller-initialize = {
      management = "${trust}/management";
    };
    atrium-reconciler = {
      management = "${trust}/management";
      personal-anthropic = "${trust}/personal-anthropic";
      family-anthropic = "${trust}/family-anthropic";
    };
  };
  program = pkgs.writeText "atrium-credential-systemd-fixture.py" ''
    import argparse
    import importlib.util
    import json
    import os
    import stat
    from datetime import UTC, datetime, timedelta
    from pathlib import Path

    # Import actual application readers only in phases that exercise them;
    # repeated unit cleanup and input staging stay stdlib-only.
    TRUST = Path("${trust}")
    FOUNDATION_UNITS = ("atrium-resolver", "atrium-device-registration")
    MODEL_SOURCES = json.loads(${builtins.toJSON (builtins.toJSON modelSources)})
    UNITS = FOUNDATION_UNITS + tuple(MODEL_SOURCES)
    PLAN = json.loads(${builtins.toJSON (builtins.toJSON runtime.tlsPlan)})

    def projector():
        spec = importlib.util.spec_from_file_location(
            "projection", "${../../hosts/forge/atrium/credential-projection.py}",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

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

    def device_settings(directory):
        from atrium_resolver.device_config import DeviceSettings

        return DeviceSettings(
            ca_certificate_path=directory / "device-ca",
            ca_private_key_path=directory / "device-ca-key",
            server_certificate_path=directory / "registration-cert",
            server_private_key_path=directory / "registration-key",
            certificate_lifetime_seconds=86400,
            max_challenges_per_principal=32,
        )

    def settings(unit, directory):
        from atrium_resolver.config import Settings

        return Settings.model_validate_json(json.dumps({
            "authorities": [{
                "id": "fixture", "issuer": "https://identity.atrium.invalid",
                "audience": "https://resolver.atrium.invalid",
                "jwks_uri": "https://identity.atrium.invalid/jwks",
            }],
            "state_directory": f"/run/{unit}-fixture/state",
            "policy_path": f"/run/{unit}-fixture/policy.json",
            "isolated_harness": True,
            "devices": device_settings(directory).model_dump(mode="json"),
        }))

    def initialization():
        from atrium_profiles.crypto import public_jwk
        from atrium_resolver.tls_bootstrap import TLSBootstrapPlan, initialize_tls
        from cryptography import x509

        PLAN["directory"] = str(TRUST)
        for entry in PLAN["authorities"] + PLAN["certificates"]:
            entry["common_name"] = "Synthetic " + entry["id"]
            if entry.get("purpose") == "server":
                entry["names"] = ["127.0.0.1"]
        initialize_tls(
            TLSBootstrapPlan.model_validate_json(json.dumps(PLAN)),
            now=int(datetime.now(UTC).timestamp()),
        )
        ca = x509.load_pem_x509_certificate((TRUST / "issuer-ca.crt.pem").read_bytes())
        write_new(TRUST / "native-jwks", json.dumps({
            "keys": [public_jwk(ca.public_key(), "fixture-native")]
        }).encode())
        write_new(TRUST / "model-management", ("sk-" + os.urandom(24).hex()).encode())
        for name in ("management", "personal-anthropic", "family-anthropic"):
            write_new(TRUST / name, ("sk-" + os.urandom(24).hex()).encode())

    def model_credential(directory, name):
        path = directory / name
        if name == "model-management":
            from atrium_resolver.litellm_native import read_controller_key

            return read_controller_key(path).get_secret_value()
        if name == "management":
            from atrium_litellm.files import read_bytes

            return read_bytes(path, secret=True, limit=16384).decode().strip()
        from atrium_litellm.controller import read_provider_credential

        return read_provider_credential(name, {"runtime_path": str(path)})

    def reproduction(unit):
        from atrium_profiles import ProfileError

        source = Path(f"/run/credentials/{unit}.service")
        module = projector()
        descriptor = os.open(source, module.DIRECTORY_FLAGS)
        try:
            module.source_metadata(descriptor, directory=True)
            assert os.fstat(descriptor).st_uid == 0
            assert stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o550
            assert os.fstatvfs(descriptor).f_flag & os.ST_RDONLY
        finally:
            os.close(descriptor)
        if unit in MODEL_SOURCES:
            from atrium_litellm.errors import ControllerError

            for name in MODEL_SOURCES[unit]:
                try:
                    model_credential(source, name)
                except ProfileError as error:
                    assert name == "model-management" and error.code == "insecure_runtime_directory"
                except ControllerError as error:
                    assert name != "model-management" and error.code == "untrusted_file"
                else:
                    raise AssertionError("actual model reader accepted root-owned credentials directly")
        else:
            from atrium_resolver.device_certificates import DeviceCertificateAuthority

            try:
                DeviceCertificateAuthority(device_settings(source))
            except ProfileError as error:
                assert error.code == "insecure_runtime_directory"
            else:
                raise AssertionError("actual systemd credential custody unexpectedly accepted directly")
        write_new(Path(f"/run/{unit}-fixture/reproduction.json"), json.dumps({
            "real_LoadCredential": True, "root_owned_acl_source": True,
            "read_only_source": True, "direct_reader_rejected": True,
        }).encode())

    def permit(unit):
        from atrium_profiles.runtime import private_directory, private_open

        directory = Path(f"/run/{unit}-credentials/material")
        module = projector()
        private_directory(directory, create=False)
        for path in directory.iterdir():
            descriptor = private_open(path, os.O_RDONLY)
            try:
                module.private_metadata(descriptor, directory=False)
                assert stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o400
            finally:
                os.close(descriptor)
        if unit in MODEL_SOURCES:
            source = Path(f"/run/credentials/{unit}.service")
            values = []
            for name in MODEL_SOURCES[unit]:
                assert (directory / name).read_bytes() == (source / name).read_bytes()
                value = model_credential(directory, name)
                assert value and value.encode() == (source / name).read_bytes()
                values.append(value)
            assert len(values) == len(set(values))
            write_new(Path(f"/run/{unit}-fixture/permit.json"), json.dumps({
                "private_projection_accepted": True,
                "real_model_readers": True, "exact_source_bytes": True,
                "uid": os.geteuid(), "credentials": sorted(MODEL_SOURCES[unit]),
            }).encode())
            return
        import ssl

        from atrium_resolver.device_certificates import DeviceCertificateAuthority
        from atrium_resolver.device_tls import registration_server_config
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes

        authority = DeviceCertificateAuthority(device_settings(directory))
        tls = registration_server_config(settings(unit, directory), port=0)
        assert tls.ssl.verify_mode == ssl.CERT_REQUIRED
        assert tls.ssl.minimum_version == ssl.TLSVersion.TLSv1_2
        if unit == "atrium-resolver":
            from atrium_resolver.home_mcp_config import HomeMCPDeployment
            from atrium_resolver.home_mcp_native import transport_context
            from atrium_resolver.litellm_native import read_controller_key

            native = HomeMCPDeployment(
                endpoint="https://native.atrium.invalid/cc/issue",
                ca_certificate_path=directory / "native-ca",
                client_certificate_path=directory / "native-client-cert",
                client_private_key_path=directory / "native-client-key",
                verification_keys_path=directory / "native-jwks",
            )
            context, public_keys = transport_context(native)
            assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
            assert public_keys.key("fixture-native").key_size == 2048
            assert read_controller_key(directory / "model-management").get_secret_value().startswith("sk-")
        ca = x509.load_pem_x509_certificate((directory / "device-ca").read_bytes())
        ca.verify_directly_issued_by(ca)
        assert ca.public_key().key_size == 2048
        assert ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
        assert ca.extensions.get_extension_for_class(x509.KeyUsage).value.key_cert_sign
        authority.require_ready(int(datetime.now(UTC).timestamp()))
        write_new(Path(f"/run/{unit}-fixture/permit.json"), json.dumps({
            "private_projection_accepted": True, "real_device_ca": True,
            "real_registration_tls_config": True,
            "optional_native_model_readers": unit == "atrium-resolver",
            "public_ca_sha256": ca.fingerprint(hashes.SHA256()).hex(),
        }).encode())

    def negative(unit, fault):
        directory = Path(f"/run/{unit}-credentials/material")
        if unit in MODEL_SOURCES:
            name = sorted(MODEL_SOURCES[unit])[0]
            if fault == "projection-link":
                descriptor = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                try:
                    try:
                        projector().private_metadata(descriptor, directory=False)
                    except ValueError as error:
                        assert str(error) == "invalid private projection custody"
                    else:
                        raise AssertionError("projector accepted a hard-linked credential")
                finally:
                    os.close(descriptor)
                # The shared resolver reader has no single-link contract;
                # the projector and controller reader enforce that invariant.
                if name == "model-management":
                    return
            else:
                assert fault == "custody"
            from atrium_litellm.errors import ControllerError
            from atrium_profiles import ProfileError

            try:
                model_credential(directory, name)
            except (ProfileError, ControllerError, OSError):
                return
            raise AssertionError("unsafe model credential custody accepted")
        import ssl

        from atrium_profiles import ProfileError
        from atrium_resolver.device_certificates import DeviceCertificateAuthority
        from atrium_resolver.device_tls import registration_server_config
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization

        device = device_settings(directory)
        if fault == "custody":
            try:
                DeviceCertificateAuthority(device)
            except (ProfileError, OSError):
                return
            raise AssertionError("unsafe custody accepted")
        ca_path = directory / "device-ca"
        key_path = directory / "device-ca-key"
        server_key = directory / "registration-key"
        path = server_key if fault == "server-pair" else key_path if fault == "ca-pair" else ca_path
        original = path.read_bytes()
        try:
            if fault == "server-pair":
                replacement = key_path.read_bytes()
            elif fault == "ca-pair":
                replacement = server_key.read_bytes()
            else:
                ca = x509.load_pem_x509_certificate(original)
                key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
                now = datetime.now(UTC)
                builder = (
                    x509.CertificateBuilder().subject_name(ca.subject).issuer_name(ca.issuer)
                    .public_key(key.public_key()).serial_number(x509.random_serial_number())
                    .not_valid_before(now - timedelta(hours=2))
                    .not_valid_after(now - timedelta(hours=1) if fault == "expired" else now + timedelta(hours=1))
                )
                for extension in ca.extensions:
                    value = extension.value
                    if fault == "not-ca" and isinstance(value, x509.BasicConstraints):
                        value = x509.BasicConstraints(ca=False, path_length=None)
                    builder = builder.add_extension(value, critical=extension.critical)
                replacement = builder.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM)
            replace(path, replacement)
            try:
                if fault == "server-pair":
                    registration_server_config(settings(unit, directory), port=0)
                else:
                    DeviceCertificateAuthority(device)
            except ssl.SSLError:
                assert fault == "server-pair"
            except ProfileError as error:
                assert fault != "server-pair"
                assert error.code == ("device_ca_expired" if fault == "expired" else "invalid_device_ca")
            else:
                raise AssertionError("invalid certificate accepted")
        finally:
            replace(path, original)
        DeviceCertificateAuthority(device)
        registration_server_config(settings(unit, directory), port=0)

    def failed_cleanup(unit):
        if os.environ.get("SERVICE_RESULT") != "success":
            parent = Path(f"/run/{unit}-credentials")
            assert not (parent / ".pending").exists()
            assert not (parent / "material").exists()

    def model_input(unit, fault):
        name = sorted(MODEL_SOURCES[unit])[-1]
        path = Path(MODEL_SOURCES[unit][name])
        saved = path.with_name(path.name + ".saved")
        if fault == "restore":
            path.unlink()
            os.rename(saved, path)
        else:
            limit = 4096 if name == "model-management" else 16384
            os.rename(path, saved)
            write_new(path, b"" if fault == "empty" else b"x" * (limit + 1))

    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=(
        "initialize", "reproduce", "permit", "negative", "failed-cleanup", "oversize", "restore", "model-input",
    ))
    parser.add_argument("unit", nargs="?", choices=UNITS)
    parser.add_argument("fault", nargs="?", choices=("custody", "projection-link", "ca-pair", "server-pair", "expired", "not-ca", "empty", "oversize", "restore"))
    args = parser.parse_args()
    try:
        if args.phase == "initialize":
            initialization()
        elif args.phase == "reproduce":
            reproduction(args.unit)
        elif args.phase == "permit":
            permit(args.unit)
        elif args.phase == "negative":
            negative(args.unit, args.fault)
        elif args.phase == "failed-cleanup":
            failed_cleanup(args.unit)
        elif args.phase == "model-input":
            model_input(args.unit, args.fault)
        elif args.phase == "oversize":
            os.rename(TRUST / "native-jwks", TRUST / "native-jwks.saved")
            write_new(TRUST / "native-jwks", b"x" * 32769)
        else:
            (TRUST / "native-jwks").unlink()
            os.rename(TRUST / "native-jwks.saved", TRUST / "native-jwks")
    except Exception as error:
        raise SystemExit("atrium_credential_fixture_" + args.phase + "_" + type(error).__name__) from None
  '';
  command = "${python}/bin/python -I -B ${program}";
  service = unit:
    let
      credentials = modelSources.${unit} or
        (sources // lib.optionalAttrs (unit == "atrium-resolver") optionalSources);
      user =
        if lib.elem unit [ "atrium-model-controller-initialize" "atrium-reconciler" ]
        then "atrium-reconciler" else "atrium-resolver";
      projected = projection.serviceConfig { inherit pkgs unit credentials; };
    in
    {
      requires = [ "atrium-credential-fixture-trust.service" ];
      after = [ "atrium-credential-fixture-trust.service" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = projected // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        RuntimeDirectory = [ projected.RuntimeDirectory "${unit}-fixture" ];
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") credentials;
        ExecStartPre = [ "${command} reproduce ${unit}" ] ++ projected.ExecStartPre;
        ExecStart = "${command} permit ${unit}";
        ExecStopPost = "${command} failed-cleanup ${unit}";
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
        StandardOutput = "null";
      };
    };
in
hostPkgs.testers.runNixOSTest {
  name = "atrium-credential-projection";
  globalTimeout = 300;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = {
      memorySize = 1024;
      cores = 1;
      vlans = [ ];
    };
    networking.hostName = "atrium-credential-fixture";
    networking.useDHCP = false;
    users.groups.atrium-resolver.gid = ids.atrium-resolver.gid;
    users.groups.atrium-trust.gid = ids.atrium-trust.gid;
    users.groups.atrium-reconciler.gid = ids.atrium-reconciler.gid;
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
    users.users.atrium-reconciler = {
      isSystemUser = true;
      uid = ids.atrium-reconciler.uid;
      group = "atrium-reconciler";
    };
    environment.systemPackages = [ pkgs.util-linux ];
    systemd.services = {
      atrium-resolver = service "atrium-resolver";
      atrium-device-registration = service "atrium-device-registration";
      atrium-model-resolver-initialize = service "atrium-model-resolver-initialize";
      atrium-model-controller-initialize = service "atrium-model-controller-initialize";
      atrium-reconciler = service "atrium-reconciler";
      atrium-credential-fixture-trust.serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "atrium-trust";
        Group = "atrium-trust";
        RuntimeDirectory = "atrium-credential-fixture-trust";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "no";
        ExecStart = "${command} initialize";
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
    probe = "setpriv --reuid 1060 --regid 1060 --clear-groups -- ${command}"
    trust_probe = "setpriv --reuid 1061 --regid 1061 --clear-groups -- ${command}"
    counts = {"reproduction": 0, "permit": 0, "deny": 0, "cleanup": 0}
    for unit in ("atrium-resolver", "atrium-device-registration"):
        root = f"/run/{unit}-credentials"
        machine.succeed(f"systemctl start {unit}")
        reproduction = json.loads(machine.succeed(f"cat /run/{unit}-fixture/reproduction.json"))
        receipt = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
        assert all(reproduction.values())
        assert receipt["real_device_ca"] and receipt["real_registration_tls_config"]
        counts["reproduction"] += 1
        counts["permit"] += 1
        for fault in ("ca-pair", "server-pair", "expired", "not-ca"):
            machine.succeed(f"{probe} negative {unit} {fault}")
            counts["deny"] += 1
        for mutation in (
            f"chown 1061:1061 {root}/material/device-ca-key",
            f"chmod 0440 {root}/material/device-ca-key",
            f"chmod 0750 {root}/material",
            f"mv {root}/material/device-ca-key {root}/material/held-key; "
            f"ln -s held-key {root}/material/device-ca-key",
        ):
            machine.succeed(mutation)
            machine.succeed(f"{probe} negative {unit} custody")
            counts["deny"] += 1
            machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
            counts["cleanup"] += 1
            machine.succeed(f"systemctl start {unit}")
            repeated = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
            assert repeated["public_ca_sha256"] == receipt["public_ca_sha256"]
        machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
        counts["cleanup"] += 1
    machine.succeed(f"{trust_probe} oversize")
    machine.fail("systemctl start atrium-resolver")
    machine.succeed("systemctl show --value -p ExecStopPost atrium-resolver | grep 'status=0'")
    machine.succeed("test ! -e /run/atrium-resolver-credentials")
    counts["deny"] += 1
    counts["cleanup"] += 1
    machine.succeed(f"{trust_probe} restore")
    machine.succeed("systemctl start atrium-resolver; systemctl stop atrium-resolver")

    model_counts = {"reproduction": 0, "permit": 0, "deny": 0, "cleanup": 0}
    link_counts = {"projector": 0, "controller_reader": 0}
    for unit, uid, name in (
        ("atrium-model-resolver-initialize", 1060, "model-management"),
        ("atrium-model-controller-initialize", 1063, "management"),
        ("atrium-reconciler", 1063, "family-anthropic"),
    ):
        root = f"/run/{unit}-credentials"
        model_probe = f"setpriv --reuid {uid} --regid {uid} --clear-groups -- ${command}"
        machine.succeed(f"systemctl start {unit}")
        reproduction = json.loads(machine.succeed(f"cat /run/{unit}-fixture/reproduction.json"))
        receipt = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
        assert all(reproduction.values())
        assert receipt["real_model_readers"] and receipt["exact_source_bytes"]
        assert receipt["uid"] == uid
        model_counts["reproduction"] += 1
        model_counts["permit"] += 1
        for fault, mutation in (
            ("custody", f"chown 1061:1061 {root}/material/{name}"),
            ("custody", f"chmod 0660 {root}/material/{name}"),
            ("custody", f"chmod 0770 {root}/material"),
            ("custody", f"mv {root}/material/{name} {root}/material/held-key; "
             f"ln -s held-key {root}/material/{name}"),
            ("projection-link", f"ln {root}/material/{name} {root}/material/linked-key"),
        ):
            machine.succeed(mutation)
            machine.succeed(f"{model_probe} negative {unit} {fault}")
            model_counts["deny"] += 1
            if fault == "projection-link":
                link_counts["projector"] += 1
                if name != "model-management":
                    link_counts["controller_reader"] += 1
            machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
            model_counts["cleanup"] += 1
            machine.succeed(f"systemctl start {unit}")
            repeated = json.loads(machine.succeed(f"cat /run/{unit}-fixture/permit.json"))
            assert repeated == receipt
        machine.succeed(f"systemctl stop {unit}; test ! -e {root}")
        model_counts["cleanup"] += 1
        for fault in ("empty", "oversize"):
            machine.succeed(f"{trust_probe} model-input {unit} {fault}")
            machine.fail(f"systemctl start {unit}")
            machine.succeed(f"systemctl show --value -p ExecStopPost {unit} | grep 'status=0'")
            machine.succeed(f"test ! -e {root}")
            model_counts["deny"] += 1
            model_counts["cleanup"] += 1
            machine.succeed(f"{trust_probe} model-input {unit} restore")
        machine.succeed(f"systemctl start {unit}; systemctl stop {unit}; test ! -e {root}")

    machine.succeed("systemctl stop atrium-credential-fixture-trust")
    machine.succeed("test ! -e ${trust}; test ! -e /run/atrium-resolver-credentials")
    counts["cleanup"] += 1
    assert counts == {"reproduction": 2, "permit": 2, "deny": 17, "cleanup": 12}
    assert model_counts == {"reproduction": 3, "permit": 3, "deny": 21, "cleanup": 24}
    assert link_counts == {"projector": 3, "controller_reader": 2}
    print(json.dumps({
        "kind": "atrium.credential-systemd",
        "foundation_counts": counts, "model_counts": model_counts,
        "model_link_refusals": link_counts,
        "actual_systemd_LoadCredential": True,
        "private_keys_confined_to_guest_run": True,
        "full_resolver_policy_gate": False, "live_operations": False,
    }, sort_keys=True))
  '';
}
