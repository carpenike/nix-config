{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  app = c.services.homelab-mcp;
  worker = c.systemd.services.homelab-mcp-finances-snapshot;
  timer = c.systemd.timers.homelab-mcp-finances-snapshot;
  exporter = c.systemd.services.homelab-mcp-finances-export;
  ingestion = c.systemd.services.homelab-mcp-finances-ingest;
  rules = lib.filterAttrs (name: _: lib.hasPrefix "finance-snapshot-" name) c.modules.alerting.rules;
  releaseGuard = lib.findFirst
    (a:
      let match = builtins.tryEval (lib.hasPrefix "finance-snapshots requires the paired MCP" a.message);
      in match.success && match.value)
    (throw "Missing finance snapshot release guard")
    c.assertions;
  checks = {
    # This check may run before the coordinator publishes/repins the release.
    # The real host assertion remains false on an old pin: no deployment bypass.
    old-release-is-refused-until-coordinator-repins =
      releaseGuard.assertion == (lib.versionAtLeast (app.package.version or "0") "0.32.0");
    same-exporter-identity-environment-and-all-effective-files =
      worker.serviceConfig.User == exporter.serviceConfig.User
      && worker.serviceConfig.Group == exporter.serviceConfig.Group
      && worker.environment == exporter.environment
      && worker.serviceConfig.EnvironmentFile == exporter.serviceConfig.EnvironmentFile
      && worker.serviceConfig.EnvironmentFile == [
        c.sops.templates."homelab-mcp-export-env".path
        c.sops.secrets."homelab-mcp/env".path
        c.sops.templates."homelab-mcp-lading-env".path
      ];
    fixed-get-only-command =
      lib.hasSuffix "--exporter ${app.package}/bin/homelab-finances-export --ingestion-state /var/lib/homelab-mcp/finances-ingest/state.json --metrics-file /run/finance-snapshot-metrics/finance_snapshot.prom --timeout 210" worker.serviceConfig.ExecStart
      && lib.hasInfix "--ingestion-state /var/lib/homelab-mcp/finances-ingest/state.json" worker.serviceConfig.ExecStart
      && lib.hasInfix "--timeout 210" worker.serviceConfig.ExecStart
      && !(lib.hasInfix "homelab-finances-ingest " worker.serviceConfig.ExecStart)
      && !(builtins.elem "homelab-mcp-finances-ingest.service" worker.requires)
      && !(worker.serviceConfig ? ExecCondition);
    bounded-oneshot-with-no-overlap-or-restart =
      worker.serviceConfig.Type == "oneshot"
      && worker.serviceConfig.TimeoutStartSec == "240s"
      && worker.serviceConfig.TimeoutStopSec == "10s"
      && worker.serviceConfig.KillMode == "control-group"
      && worker.serviceConfig.Restart == "no"
      && worker.wantedBy == [ ]
      && !(worker.serviceConfig.RemainAfterExit or false);
    separate-five-minute-timer =
      timer.timerConfig.OnUnitActiveSec == "5m"
      && timer.timerConfig.OnBootSec == "1m"
      && timer.timerConfig.AccuracySec == "10s"
      && timer.timerConfig.Unit == "homelab-mcp-finances-snapshot.service"
      && timer.wantedBy == [ "timers.target" ];
    no-state-initialization-or-quota-writes =
      !(worker.serviceConfig ? StateDirectory)
      && worker.serviceConfig.ReadOnlyPaths == exporter.serviceConfig.ReadOnlyPaths
      && builtins.elem "/var/lib/homelab-mcp" worker.serviceConfig.ReadOnlyPaths
      && worker.serviceConfig.ReadWritePaths == [ "/run/finance-snapshot-metrics" ]
      && worker.serviceConfig.ProtectSystem == "strict"
      && worker.serviceConfig.NoNewPrivileges;
    mount-and-existing-database-provisioning-are-required =
      worker.unitConfig.RequiresMountsFor == [ "/var/lib/homelab-mcp" ]
      && worker.unitConfig.AssertPathIsMountPoint == [ "/var/lib/homelab-mcp" ]
      && lib.all (name: builtins.elem name worker.requires && builtins.elem name worker.after)
        [ "zfs-service-datasets.service" "postgresql-provision-databases.service" ];
    aggregate-file-only-with-no-new-reader-privileges =
      worker.serviceConfig.UMask == "0027"
      && !(builtins.elem "node-exporter" c.users.users.homelab-mcp.extraGroups)
      && builtins.elem "d /run/finance-snapshot-metrics 2750 homelab-mcp node-exporter -" c.systemd.tmpfiles.rules
      && builtins.elem "L+ ${c.modules.monitoring.nodeExporter.textfileCollector.directory}/finance_snapshot.prom - - - - /run/finance-snapshot-metrics/finance_snapshot.prom" c.systemd.tmpfiles.rules;
    default-nightly-remains-unconditional-and-unchanged =
      exporter.serviceConfig.ExecStart == "${app.package}/bin/homelab-finances-export"
      && !(exporter.serviceConfig ? ExecCondition)
      && c.systemd.timers.homelab-mcp-finances-export.timerConfig.OnCalendar == "*-*-* 05:30:00 America/New_York"
      && c.systemd.timers.homelab-mcp-finances-export.timerConfig.Persistent
      && c.systemd.timers.homelab-mcp-finances-export.timerConfig.RandomizedDelaySec == "120";
    bank-owner-quota-and-skip-semantics-are-unchanged =
      app.financesIngest.minimumIntervalSeconds == 86400
      && c.systemd.timers.homelab-mcp-finances-ingest.timerConfig.OnCalendar == "*-*-* *:00/15:00 UTC"
      && ingestion.serviceConfig.ExecCondition == "${app.package}/bin/homelab-finances-ingest due"
      && ingestion.serviceConfig.ExecStart == "${app.package}/bin/homelab-finances-ingest run --allow-bank-sync --distinguish-degraded"
      && ingestion.serviceConfig.SuccessExitStatus == [ 3 ]
      && !(ingestion.unitConfig ? OnSuccess)
      && !(ingestion.serviceConfig ? ExecStartPost);
    high-alerts-reuse-existing-oncall-routing =
      builtins.length (builtins.attrNames rules) == 6
      && lib.all
        (r: r.severity == "high" && r.labels.service == "finance-snapshot"
        && r.labels.category == "finance" && r.labels.host == "forge")
        (builtins.attrValues rules)
      && c.modules.alerting.enable
      && c.modules.alerting.receivers.oncall.enable
      && !(worker.unitConfig ? OnFailure)
      && !(worker.unitConfig ? OnSuccess);
    other-snapshot-activation-contracts-are-satisfied =
      lib.all
        (a:
          a.assertion
          || !(lib.hasPrefix "finance-snapshots" a.message)
          || a.message == releaseGuard.message)
        c.assertions;
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ]) "Finance snapshot regressions: ${lib.concatStringsSep ", " failed}";
checks
