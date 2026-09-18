{ inputs, pkgs }:
let
  forge = import ./pre-adoption.nix { inherit inputs; };
  native = (forge.extendModules {
    modules = [{
      services.atriumForge.adoption.native = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  clientSettings = config: {
    inherit (config.services.hermes-agent.settings) mcp_servers platform_toolsets;
  };
  data = pkgs.writeText "atrium-hermes-transition-input.json" (builtins.toJSON {
    legacy = clientSettings forge.config;
    adopted = clientSettings native;
  });
  mergeScript = import (inputs.hermes-agent + "/nix/configMergeScript.nix") { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.runCommand "atrium-hermes-config-transition"
{
  nativeBuildInputs = [ python ];
  PYTHONDONTWRITEBYTECODE = "1";
}
  ''
    python - <<'PY' > "$out"
    import copy
    import json
    import os
    import subprocess
    from pathlib import Path

    import yaml

    os.umask(0o077)
    data = json.loads(Path("${data}").read_text())
    root = Path.cwd() / "private-hermes-fixture"
    root.mkdir(mode=0o700)
    cache = root / "mcp-tokens"
    cache.mkdir(mode=0o700)
    managed = {"holthome", "holthome-telegram", "atrium-finance", "atrium-status"}
    unrelated = {"enabled": True, "url": "https://unrelated.atrium.invalid/mcp"}
    for name in sorted(managed | {"unrelated"}):
        for suffix in (".json", ".client.json", ".meta.json"):
            (cache / (name + suffix)).write_text(json.dumps({"fixture": name + suffix}))
    original_cache = {path.name: path.read_bytes() for path in cache.iterdir()}
    config = root / "config.yaml"
    incoming = root / "nix.json"

    def initial(settings):
        result = copy.deepcopy(settings)
        result["mcp_servers"]["unrelated"] = copy.deepcopy(unrelated)
        result["unrelated-setting"] = {"keep": True}
        return result

    def merge(settings):
        incoming.write_text(json.dumps(settings))
        subprocess.run(["${mergeScript}", str(incoming), str(config)], check=True)
        return yaml.safe_load(config.read_text())

    def active(state):
        return {
            name for name, value in state["mcp_servers"].items()
            if name in managed and value.get("enabled", True)
        }

    transitions = [
        ("adopted", {"atrium-finance", "atrium-status"}),
        ("legacy", {"holthome", "holthome-telegram"}),
        ("adopted", {"atrium-finance", "atrium-status"}),
    ]
    config.write_text(yaml.safe_dump(initial(data["legacy"])))
    for name, expected in transitions:
        result = merge(data[name])
        assert active(result) == expected, "inactive managed aliases survived activation"
        for alias in expected:
            assert result["mcp_servers"][alias] == data[name]["mcp_servers"][alias]
        assert result["platform_toolsets"] == data[name]["platform_toolsets"]
        assert result["mcp_servers"]["unrelated"] == unrelated
        assert result["unrelated-setting"] == {"keep": True}
        assert merge(data[name]) == result, "configuration merge was not idempotent"
        assert {path.name: path.read_bytes() for path in cache.iterdir()} == original_cache

    for source, target, expected in [
        ("legacy", "adopted", {"atrium-finance", "atrium-status"}),
        ("adopted", "legacy", {"holthome", "holthome-telegram"}),
    ]:
        config.write_text(yaml.safe_dump(initial(data[source])))
        unsafe = copy.deepcopy(data[target])
        for alias in managed - expected:
            del unsafe["mcp_servers"][alias]
        result = merge(unsafe)
        assert active(result) == managed, "omission regression did not reproduce"
        assert active(result) != expected, "transition guard accepted stale enabled aliases"
    assert {path.name: path.read_bytes() for path in cache.iterdir()} == original_cache
    print(json.dumps({
        "kind": "atrium.hermes-config-transition",
        "status": "passed",
        "actual_pinned_merge_script": True,
        "transition_and_idempotence_runs": 6,
        "omitted_disable_regressions_detected": 2,
        "synthetic_cache_files_preserved": len(original_cache),
        "unrelated_configuration_preserved": True,
        "runtime_gate_evidence": False,
        "live_operations": False,
    }, sort_keys=True))
    PY
  ''
