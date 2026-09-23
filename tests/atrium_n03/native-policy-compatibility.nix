{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  native = inputs.homelab-mcp;
  package = native.packages.${pkgs.stdenv.hostPlatform.system}.default;
  python = pkgs.python313.withPackages (ps: [ (ps.toPythonModule package) ]);
  documents = inputs.atrium.lib.renderForGateway {
    registry = c.services.atrium.registry;
    nativeVersion = c.services.atrium.litellmVersion;
  };
  expected = lib.mapAttrs
    (_: instance: {
      inherit (instance) domain;
      target = c.services.atrium.registry.deployments.home-mcp.endpoint + instance.route;
    })
    (lib.filterAttrs (_: instance: instance.deployment == "home-mcp")
      c.services.atrium.registry.instances);
  data = pkgs.writeText "atrium-native-policy-compatibility.json" (builtins.toJSON {
    inherit expected;
    policy = pkgs.writeText "atrium-native-consumer-policy.json" (builtins.toJSON documents.resolver);
    issuer = c.services.atrium.registry.deployments.home-mcp.endpoint;
    current_policy_source = inputs.atrium + "/resolver/src/atrium_resolver/policy.py";
    vendor = native + "/vendor/atrium-source";
  });
in
pkgs.runCommand "atrium-native-policy-compatibility"
{
  nativeBuildInputs = [ python ];
  PYTHONDONTWRITEBYTECODE = "1";
}
  ''
    python -I -B - <<'PY' > "$out"
    import ast
    import copy
    import inspect
    import json
    from pathlib import Path
    from types import SimpleNamespace

    import atrium_profiles.models
    import atrium_resolver.policy
    import atrium_resolver.policy_schema
    from homelab_mcp.view_policy import NativeViewRegistry, ViewPolicyError

    data = json.loads(Path("${data}").read_text())
    vendor = Path(data["vendor"])
    for module, relative in (
        (atrium_profiles.models, "profiles/src/atrium_profiles/models.py"),
        (atrium_resolver.policy, "resolver/src/atrium_resolver/policy.py"),
        (atrium_resolver.policy_schema, "resolver/src/atrium_resolver/policy_schema.py"),
    ):
        installed = Path(inspect.getfile(module))
        assert str(installed).startswith("/nix/store/")
        assert installed.read_bytes() == (vendor / relative).read_bytes()

    def contracts(source):
        return {
            node.name: ast.dump(node, include_attributes=False)
            for node in ast.parse(source).body
            if isinstance(node, ast.ClassDef) and node.name in ("Decision", "PolicyDenied")
        }

    current_contract = contracts(Path(data["current_policy_source"]).read_text())
    installed_contract = contracts(Path(inspect.getfile(atrium_resolver.policy)).read_text())
    assert set(current_contract) == set(installed_contract) == {"Decision", "PolicyDenied"}
    assert current_contract == installed_contract
    original = json.loads(Path(data["policy"]).read_text())
    policy = Path.cwd() / "current-host-policy.json"

    def publish(value):
        policy.write_text(json.dumps(value))
        policy.chmod(0o600)

    def registry(issuer=data["issuer"]):
        return NativeViewRegistry(SimpleNamespace(
            issuer=issuer, atrium_view_policy=policy, atrium_issuance=None,
        ))

    publish(original)
    views = registry()
    assert {view.resource.id for view in views.active_views()} == set(data["expected"])
    for identifier, expected in data["expected"].items():
        view = views.view(identifier)
        assert view.resource.target == expected["target"]
        assert view.resource.domain == expected["domain"]
        assert views.for_target(expected["target"]).resource == view.resource

    def refused(action):
        try:
            action()
        except ViewPolicyError:
            return
        raise AssertionError("native policy accepted a refused configuration or target")

    refused(lambda: views.view("undeclared-view"))
    refused(lambda: views.for_target(data["issuer"] + "/undeclared"))
    refused(lambda: registry("https://foreign.invalid").view("personal-finance"))
    changed = copy.deepcopy(original)
    changed["instances"]["personal-finance"]["status"] = "retired"
    publish(changed)
    refused(lambda: views.view("personal-finance"))
    changed = copy.deepcopy(original)
    changed["instances"]["personal-finance"]["scopes"] = ["unclassified-scope"]
    publish(changed)
    refused(lambda: views.view("personal-finance"))
    publish(original)
    policy.chmod(0o666)
    refused(lambda: views.view("personal-finance"))
    publish(original)
    assert views.view("personal-finance").resource.target == data["expected"]["personal-finance"]["target"]
    print(json.dumps({
        "kind": "atrium.current-policy-installed-native-consumption",
        "views": len(data["expected"]),
        "refusals": 6,
        "installed_vendored_reader_verified": True,
        "shared_decision_contract_unchanged": True,
        "runtime_gate_evidence": False,
        "live_operations": False,
    }, sort_keys=True))
    PY
  ''
