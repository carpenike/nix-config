{ pkgs }:
let
  rules = import ../../hosts/forge/services/finance-snapshots/alerts.nix {
    worker = "homelab-mcp-finances-snapshot";
    host = "forge";
  };
  ruleFile = pkgs.writeText "finance-snapshot-rules.json" (builtins.toJSON {
    groups = [{
      name = "finance-snapshot";
      rules = pkgs.lib.mapAttrsToList
        (_: r: {
          alert = r.alertname;
          inherit (r) expr for annotations;
          labels = r.labels // { inherit (r) severity; };
        })
        rules;
    }];
  });
  fixtures = pkgs.writeText "finance-snapshot-fixtures.json" (builtins.toJSON (
    import ./rule-fixtures.nix { inherit rules; inherit (pkgs) lib; }
  ));
in
pkgs.runCommand "finance-snapshot-monitoring-tests"
{
  nativeBuildInputs = [ pkgs.prometheus.cli pkgs.python3 ];
  PYTHONDONTWRITEBYTECODE = "1";
  SNAPSHOT_COLLECTOR = ../../hosts/forge/services/finance-snapshots/collect.py;
}
  ''
    cp ${ruleFile} rules.json
    cp ${fixtures} fixtures.json
    promtool check rules rules.json
    promtool test rules fixtures.json
    python3 ${./test-collector.py}
    touch "$out"
  ''
