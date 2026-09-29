{ pkgs }:
let
  rules = import ../../hosts/forge/services/finance-ingestion/alerts.nix {
    worker = "homelab-mcp-finances-ingest";
    collector = "finance-ingest-metrics";
    host = "forge";
    runGraceSeconds = 600;
  };
  ruleFile = pkgs.writeText "finance-ingestion-rules.json" (
    builtins.toJSON {
      groups = [
        {
          name = "finance-ingestion";
          rules = pkgs.lib.mapAttrsToList
            (_: r: {
              alert = r.alertname;
              inherit (r) expr for annotations;
              labels = r.labels // {
                inherit (r) severity;
              };
            })
            rules;
        }
      ];
    }
  );
  fixtures = pkgs.writeText "finance-ingestion-fixtures.json" (
    builtins.toJSON (
      import ./rule-fixtures.nix {
        inherit rules;
        inherit (pkgs) lib;
      }
    )
  );
in
pkgs.runCommand "finance-ingestion-monitoring-tests"
{
  nativeBuildInputs = [
    pkgs.prometheus.cli
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
  ];
}
  ''
    cp ${ruleFile} rules.json
    cp ${fixtures} fixtures.json
    promtool check rules rules.json
    promtool test rules fixtures.json
    bash ${./test-collector.sh} ${../../hosts/forge/services/finance-ingestion/collect.sh}
    touch "$out"
  ''
