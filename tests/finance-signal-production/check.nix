{ pkgs, package, source, systemdFailureExpr, productionEnabled }:
let
  python = pkgs.python313.withPackages (ps: [ (ps.toPythonModule package) ps.pytest ps.pytest-asyncio ps.pytest-httpx ]);
  rules = import ../../hosts/forge/services/finance-signal-production/alerts.nix { host = "forge"; };
  ruleFile = pkgs.writeText "finance-signal-rules.json" (builtins.toJSON {
    groups = [{
      name = "finance-signal";
      rules = pkgs.lib.mapAttrsToList
        (_: r: {
          alert = r.alertname;
          inherit (r) expr for annotations;
          labels = r.labels // { inherit (r) severity; };
        })
        rules;
    }];
  });
  fixtures = pkgs.writeText "finance-signal-fixtures.json" (builtins.toJSON (
    import ./rule-fixtures.nix { inherit rules; inherit (pkgs) lib; }
  ));
  genericRule = pkgs.writeText "finance-signal-generic-rule.json" (builtins.toJSON {
    groups = [{
      name = "actual-generic-failure";
      rules = [{ record = "generic_unit_failure"; expr = systemdFailureExpr; }];
    }];
  });
  genericFixtures = pkgs.writeText "finance-signal-generic-fixtures.json" (builtins.toJSON {
    rule_files = [ "generic-rule.json" ];
    evaluation_interval = "1m";
    tests = [{
      interval = "1m";
      input_series = map
        (name: {
          series = ''node_systemd_unit_state{name="${name}",state="failed",instance="forge",job="node"}'';
          values = "1+0x2";
        })
        [ "finance-signal-report@daily.service" "finance-signal-report@weekly.service" "finance-signal-capture.service" "postgresql.service" ];
      promql_expr_test = map
        (name: {
          expr = ''count(generic_unit_failure{name="${name}"}) or vector(0)'';
          eval_time = "1m";
          exp_samples = [{
            labels = "{}";
            value = if productionEnabled && pkgs.lib.hasPrefix "finance-signal-report@" name then 0 else 1;
          }];
        })
        [ "finance-signal-report@daily.service" "finance-signal-report@weekly.service" "finance-signal-capture.service" "postgresql.service" ];
    }];
  });
in
pkgs.runCommand "finance-signal-production-tests"
{
  nativeBuildInputs = [ python pkgs.prometheus.cli pkgs.ruff pkgs.shellcheck ];
  FINANCE_SIGNAL_RUNTIME = ../../hosts/forge/services/finance-signal-production/runtime.py;
  PYTHONDONTWRITEBYTECODE = "1";
  SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
}
  ''
    python3 ${./test-runtime.py}
    ruff check "$FINANCE_SIGNAL_RUNTIME" ${./test-runtime.py}
    ruff format --check "$FINANCE_SIGNAL_RUNTIME" ${./test-runtime.py}
    shellcheck ${./run.sh}
    cp ${ruleFile} rules.json
    cp ${fixtures} fixtures.json
    promtool check rules rules.json
    promtool test rules fixtures.json
    cp ${genericRule} generic-rule.json
    cp ${genericFixtures} generic-fixtures.json
    promtool test rules generic-fixtures.json
    # Installed native code, source-owned mock transports/fixtures; no real calls.
    PYTHONPATH=${source} python3 -m pytest -q --tb=short -p no:cacheprovider \
      ${source}/tests/test_finance_signal_report_job.py \
      ${source}/tests/test_finance_signal_listener.py
    touch "$out"
  ''
