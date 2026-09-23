{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  configuration = import ./pre-adoption.nix { inherit inputs; };
  forge = configuration.config;
  adopted = (configuration.extendModules {
    modules = [{
      services.atriumForge.adoption.models = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  nativeAdopted = (configuration.extendModules {
    modules = [{
      services.atriumForge.adoption.native = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  healthCommand = config: prefix:
    let
      matches = lib.filter (lib.hasPrefix prefix)
        config.virtualisation.oci-containers.containers.litellm.extraOptions;
    in
    assert builtins.length matches == 1;
    lib.removePrefix prefix (builtins.head matches);
  gatewayConfig = config:
    let
      suffix = ":/app/config.yaml:ro";
      matches = lib.filter (lib.hasSuffix suffix)
        config.virtualisation.oci-containers.containers.litellm.volumes;
    in
    assert builtins.length matches == 1;
    lib.removeSuffix suffix (builtins.head matches);
  registry = forge.services.atrium.registry;
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  models = import ../../hosts/forge/atrium/models.nix {
    inherit lib runtime registry;
    ids = import ../../lib/service-uids.nix { };
  };
  bootstrap = import ../../hosts/forge/atrium/bootstrap.nix { inherit lib registry; };
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
  python = pkgs.python312.withPackages (ps: (map ps.toPythonModule [
    packages.resolver
    packages.credential-profiles
    packages.atrium-litellm-controller
    packages.atrium-litellm-admission
  ]) ++ [ ps.pyyaml ]);
  data = {
    inherit bootstrap;
    gateway_configs = {
      adopted = gatewayConfig adopted;
      unadopted = gatewayConfig forge;
    };
    health_commands = {
      adopted_regular = healthCommand adopted "--health-cmd=";
      adopted_startup = healthCommand adopted "--health-startup-cmd=";
      unadopted_regular = healthCommand forge "--health-cmd=";
      unadopted_startup = healthCommand forge "--health-startup-cmd=";
    };
    authority_token_types = lib.mapAttrs (_: authority: authority.tokenType) registry.authorities;
    instance_acls = lib.mapAttrs
      (_: instance: {
        inherit (instance) domain acl;
      })
      registry.instances;
    human_template_acls = lib.mapAttrs
      (_: template: {
        inherit (template) domain acl;
      })
      (registry.routeTemplates
        // lib.filterAttrs (_: template: template.credentialKind == "client") registry.modelTemplates);
    group_evidence = runtime.adoption.identity.group_evidence;
    resolver = runtime.resolver // { litellm = models.resolver; };
    broker_resolver = builtins.fromJSON nativeAdopted.environment.etc."atrium/runtime/atrium-resolver.json".text;
    admission = models.admission;
    controller = models.controller;
    native = runtime.native;
    native_policy = runtime.nativePolicyTemplate;
    renderer = ../../hosts/forge/atrium/runtime-bindings.py;
  };
in
pkgs.runCommand "atrium-forge-cloud-schema"
{
  nativeBuildInputs = [ python ];
  PYTHONDONTWRITEBYTECODE = "1";
}
  ''
    python - <<'PY' > "$out"
    import json
    import os
    import shlex
    import subprocess
    import sys
    from datetime import datetime, timedelta, timezone
    from pathlib import Path
    from types import SimpleNamespace
    from unittest.mock import patch
    from urllib.error import URLError

    import yaml
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ed25519
    from cryptography.hazmat.primitives.serialization import Encoding
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    from atrium_resolver.config import Bootstrap, Settings
    from atrium_resolver.native_policy_config import NativePolicySettings
    from atrium_resolver.policy import PolicySeed
    from atrium_admission.models import Settings as AdmissionSettings
    from atrium_litellm.controller import Controller
    from atrium_litellm.ledger import Ledger
    from atrium_litellm.native import SAFE_ROUTER

    data = json.loads(${builtins.toJSON (builtins.toJSON data)})
    gateway_configs = {
        name: yaml.safe_load(Path(path).read_bytes())
        for name, path in data["gateway_configs"].items()
    }
    adopted_router = gateway_configs["adopted"]["router_settings"]
    for name, expected in SAFE_ROUTER.items():
        assert adopted_router.get(name) == expected, "rendered gateway violates controller routing contract"
    assert gateway_configs["unadopted"]["router_settings"]["num_retries"] == 2
    assert adopted_router["routing_strategy"] == gateway_configs["unadopted"]["router_settings"]["routing_strategy"]
    assert adopted_router["timeout"] == gateway_configs["unadopted"]["router_settings"]["timeout"]
    settings = Settings.model_validate_json(json.dumps(data["resolver"]))
    broker_settings = Settings.model_validate_json(json.dumps(data["broker_resolver"]))
    broker = broker_settings.home_mcp.deployments["home-mcp"]
    assert broker.endpoint == "https://mcp.holthome.net/cc/issue"
    assert broker.issuer == "https://mcp.holthome.net"
    assert broker.transport_endpoint == "https://127.0.0.1:9200/cc/issue"
    assert broker.request_endpoint == "https://127.0.0.1:9200/cc/issue"
    assert broker.verification_keys_path == Path("/run/atrium-resolver-credentials/material/native-jwks")
    admission = AdmissionSettings.model_validate_json(json.dumps(data["admission"]))
    enrollment = Bootstrap.model_validate_json(json.dumps(data["bootstrap"]["enrollment"]))
    ordinary = PolicySeed.model_validate_json(json.dumps(data["bootstrap"]["ordinary"]))
    opus = PolicySeed.model_validate_json(json.dumps(data["bootstrap"]["opus"]))
    finance = PolicySeed.model_validate_json(json.dumps(data["bootstrap"]["financeClients"]))
    assert settings.isolated_harness is False
    assert settings.litellm.native_version == admission.native_version == "v1.100.1"
    assert admission.environment == "production" and not admission.isolated
    assert [p.id for p in enrollment.principals if p.kind == "human"] == ["ryan"]
    assert not data["bootstrap"]["groups"]["observations_seeded"]
    assert len(ordinary.grants) == 5 and len(opus.grants) == 1
    assert all(not grant.can_delegate for grant in ordinary.grants)
    assert all(grant.request.models != ("cc.personal.ryan.opus",) for grant in ordinary.grants)
    assert opus.grants[0].request.models == ("cc.personal.ryan.opus",)
    assert {grant.request.template_id for grant in finance.grants} == {
        "cc.personal.ryan.finance", "cc.personal.ryan.scribe", "cc.personal.ryan.status",
        "cc.personal.ryan.money",
    }
    assert len(finance.grants) == 4
    assert all(
        grant.principal == "ryan" and not grant.can_delegate
        and grant.request.lifetime_seconds == 900
        for grant in finance.grants
    )
    assert data["controller"]["association_publisher_uid"] != admission.producers[1].publisher_uid
    assert hasattr(Controller, "publish_service_associations") and hasattr(Ledger, "initialize")

    human_ids = {p.id for p in enrollment.principals if p.kind == "human"}
    required_groups = {
        "personal:ryan": ["atrium-personal-ryan"],
        "family:holt": ["atrium-family"],
    }
    automation_instances = {"personal-scribe", "personal-status"}
    automation_templates = {"cc.personal.ryan.scribe", "cc.personal.ryan.status"}
    owner_instances = automation_instances | {"personal-money"}
    owner_templates = automation_templates | {"cc.personal.ryan.money"}
    assert automation_instances <= data["instance_acls"].keys()
    assert automation_templates <= data["human_template_acls"].keys()
    explicit_automation_acl = {"principals": ["ryan"], "groups": []}
    for name, instance in data["instance_acls"].items():
        if name in owner_instances:
            assert instance["domain"] == "personal:ryan"
            assert instance["acl"] == explicit_automation_acl
        else:
            assert not human_ids.intersection(instance["acl"]["principals"]), "human principal ACL bypass"
            assert instance["acl"]["groups"] == required_groups[instance["domain"]]
    for name, template in data["human_template_acls"].items():
        if name in owner_templates:
            assert template["domain"] == "personal:ryan"
            assert template["acl"] == explicit_automation_acl
        else:
            assert template["acl"]["principals"] == [], "human template bypasses group evidence"
            assert template["acl"]["groups"] == required_groups[template["domain"]]
    assert set(data["authority_token_types"].values()) == {"access_token"}
    assert settings.group_authority == "pocketid"
    assert data["group_evidence"]["status"] == "accepted-unconfigured"
    assert data["group_evidence"]["amendment"]["accepted"] is True
    assert data["group_evidence"]["configured"] is False
    assert data["group_evidence"]["admitted_client_ids"] == []
    assert data["group_evidence"]["missing_groups"] == "deny"
    assert not data["group_evidence"]["principal_acl_fallback"]
    assert not data["group_evidence"]["unsigned_userinfo_fallback"]
    assert not data["group_evidence"]["identity_carrier_change"]
    assert not data["group_evidence"]["provenance"]["reproduced_by_this_deployment"]

    for phase, command in data["health_commands"].items():
        words = shlex.split(command)
        assert len(words) == 3 and words[:2] == ["python3", "-c"]
        expected = ("https://llm.holthome.net/health/liveliness"
                    if phase.startswith("adopted_")
                    else "http://127.0.0.1:4000/health/liveliness")
        probe = compile(words[2], "<evaluated-container-health-command>", "exec")
        for status, exit_code in ((200, 0), (503, 1)):
            with patch("urllib.request.urlopen", return_value=SimpleNamespace(status=status)) as request:
                try:
                    exec(probe, {})
                except SystemExit as error:
                    assert error.code == exit_code
                else:
                    raise AssertionError("health command did not return a status")
                request.assert_called_once_with(expected, timeout=5)
        with patch("urllib.request.urlopen", side_effect=URLError("unavailable")) as request:
            try:
                exec(probe, {})
            except URLError:
                pass
            else:
                raise AssertionError("health transport failure became success")
            request.assert_called_once_with(expected, timeout=5)

    root = Path.cwd() / "binding-check"
    root.mkdir(mode=0o700)
    output = root / "output"
    output.mkdir(mode=0o700)
    now = datetime.now(timezone.utc)
    key = ed25519.Ed25519PrivateKey.generate()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Atrium binding test")])
    def certificate(usage):
        return (x509.CertificateBuilder().subject_name(name).issuer_name(name)
          .public_key(key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(hours=1))
          .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
          .add_extension(x509.ExtendedKeyUsage([usage]), critical=True).sign(key, None))
    client = certificate(ExtendedKeyUsageOID.CLIENT_AUTH)
    (root / "client.pem").write_bytes(client.public_bytes(Encoding.PEM))
    (root / "server.pem").write_bytes(certificate(ExtendedKeyUsageOID.SERVER_AUTH).public_bytes(Encoding.PEM))
    (root / "policy.json").write_text(json.dumps(data["native_policy"]))
    command = [
        sys.executable, data["renderer"], "native-policy", "--template", str(root / "policy.json"),
        "--client-certificate", str(root / "client.pem"), "--output", str(output / "policy.json"),
    ]
    permitted = subprocess.run(command, capture_output=True, timeout=30)
    assert permitted.returncode == 0, "real public client certificate was refused"
    actual = Settings.model_validate_json((output / "policy.json").read_bytes())
    assert actual.native_policy.adapters[0].certificates == (client.fingerprint(hashes.SHA256()).hex(),)
    before = (output / "policy.json").read_bytes()
    wrong = command.copy()
    wrong[wrong.index("--client-certificate") + 1] = str(root / "server.pem")
    denied = subprocess.run(wrong, capture_output=True, timeout=30)
    assert denied.returncode != 0 and (output / "policy.json").read_bytes() == before
    assert b"PRIVATE KEY" not in permitted.stdout + permitted.stderr + denied.stdout + denied.stderr
    assert os.stat(output / "policy.json").st_mode & 0o777 == 0o600

    profile = {
        "resource": data["native"]["resource"], "cutover_at": int(now.timestamp()),
        "legacy_refresh_until": int(now.timestamp()) + 86400, "legacy_mappings": [],
    }
    (root / "profile.json").write_text(json.dumps(profile))
    (root / "native.json").write_text(json.dumps(data["native"]))
    command = [
        sys.executable, data["renderer"], "native-environment", "--template", str(root / "native.json"),
        "--profile", str(root / "profile.json"), "--client-certificate", str(root / "client.pem"),
        "--output", str(output / "native.env"),
    ]
    assert subprocess.run(command, capture_output=True, timeout=30).returncode == 0
    before = (output / "native.env").read_bytes()
    profile["resource"] = dict(profile["resource"], target="https://wrong.atrium.invalid/mcp")
    (root / "profile.json").write_text(json.dumps(profile))
    assert subprocess.run(command, capture_output=True, timeout=30).returncode != 0
    assert (output / "native.env").read_bytes() == before
    print(json.dumps({
        "kind": "atrium.forge-cloud-schema", "status": "passed",
        "real_runtime_schema_parsers": True, "certificate_derived_bindings": True,
        "wrong_certificate_refused": True, "wrong_native_target_refused": True,
        "ordinary_human_acls_remain_group_only": True,
        "explicit_automation_principal_acls": ["personal-scribe", "personal-status"],
        "separate_bounded_finance_grants_parsed": True,
        "identity_carrier_remains_access_token": True,
        "group_carrier_integration": "accepted-unconfigured",
        "native_group_measurements_reproduced": False,
        "evaluated_container_health_commands_smoked": True,
        "health_network_boundary_exercised": False,
        "canonical_native_issuer_and_private_transport_schema": True,
        "runtime_gate_evidence": False, "live_operations": False,
    }))
    PY
  ''
