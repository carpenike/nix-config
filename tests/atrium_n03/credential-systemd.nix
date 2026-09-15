{ pkgs, resolverPackage, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  ids = import ../../lib/service-uids.nix { };
  python = pkgs.python312.withPackages (ps: [ (ps.toPythonModule resolverPackage) ]);
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
  program = pkgs.writeText "atrium-credential-systemd-fixture.py" ''
    import argparse
    import importlib.util
    import json
    import os
    import ssl
    import stat
    from datetime import UTC, datetime, timedelta
    from pathlib import Path

    from atrium_profiles import ProfileError
    from atrium_profiles.crypto import public_jwk
    from atrium_profiles.runtime import private_directory, private_open
    from atrium_resolver.config import Settings
    from atrium_resolver.device_certificates import DeviceCertificateAuthority
    from atrium_resolver.device_config import DeviceSettings
    from atrium_resolver.device_tls import registration_server_config
    from atrium_resolver.home_mcp_config import HomeMCPDeployment
    from atrium_resolver.home_mcp_native import transport_context
    from atrium_resolver.litellm_native import read_controller_key
    from atrium_resolver.tls_bootstrap import TLSBootstrapPlan, initialize_tls
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization

    TRUST = Path("${trust}")
    UNITS = ("atrium-resolver", "atrium-device-registration")
    PLAN = json.loads(${builtins.toJSON (builtins.toJSON runtime.tlsPlan)})

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
        return DeviceSettings(
            ca_certificate_path=directory / "device-ca",
            ca_private_key_path=directory / "device-ca-key",
            server_certificate_path=directory / "registration-cert",
            server_private_key_path=directory / "registration-key",
            certificate_lifetime_seconds=86400,
            max_challenges_per_principal=32,
        )

    def settings(unit, directory):
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

    def reproduction(unit):
        source = Path(f"/run/credentials/{unit}.service")
        spec = importlib.util.spec_from_file_location(
            "projection", "${../../hosts/forge/atrium/credential-projection.py}",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        descriptor = os.open(source, module.DIRECTORY_FLAGS)
        try:
            module.source_metadata(descriptor, directory=True)
            assert os.fstat(descriptor).st_uid == 0
            assert stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o550
            assert os.fstatvfs(descriptor).f_flag & os.ST_RDONLY
        finally:
            os.close(descriptor)
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
        directory = Path(f"/run/{unit}-credentials/material")
        private_directory(directory, create=False)
        for path in directory.iterdir():
            descriptor = private_open(path, os.O_RDONLY)
            try:
                assert stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o400
            finally:
                os.close(descriptor)
        authority = DeviceCertificateAuthority(device_settings(directory))
        tls = registration_server_config(settings(unit, directory), port=0)
        assert tls.ssl.verify_mode == ssl.CERT_REQUIRED
        assert tls.ssl.minimum_version == ssl.TLSVersion.TLSv1_2
        if unit == "atrium-resolver":
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

    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=(
        "initialize", "reproduce", "permit", "negative", "failed-cleanup", "oversize", "restore",
    ))
    parser.add_argument("unit", nargs="?", choices=UNITS)
    parser.add_argument("fault", nargs="?", choices=("custody", "ca-pair", "server-pair", "expired", "not-ca"))
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
      credentials = sources // lib.optionalAttrs (unit == "atrium-resolver") optionalSources;
      projected = projection.serviceConfig { inherit pkgs unit credentials; };
    in
    {
      requires = [ "atrium-credential-fixture-trust.service" ];
      after = [ "atrium-credential-fixture-trust.service" ];
      serviceConfig = projected // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "atrium-resolver";
        Group = "atrium-resolver";
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
  name = "atrium-foundation-credential-projection";
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
    environment.systemPackages = [ pkgs.util-linux ];
    systemd.services = {
      atrium-resolver = service "atrium-resolver";
      atrium-device-registration = service "atrium-device-registration";
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
    machine.succeed("systemctl stop atrium-credential-fixture-trust")
    machine.succeed("test ! -e ${trust}; test ! -e /run/atrium-resolver-credentials")
    counts["cleanup"] += 1
    assert counts == {"reproduction": 2, "permit": 2, "deny": 17, "cleanup": 12}
    print(json.dumps({
        "kind": "atrium.foundation-credential-systemd",
        "counts": counts, "actual_systemd_LoadCredential": True,
        "private_keys_confined_to_guest_run": True,
        "full_resolver_policy_gate": False, "live_operations": False,
    }, sort_keys=True))
  '';
}
