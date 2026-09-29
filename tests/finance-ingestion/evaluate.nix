{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  cfg = c.services.homelab-mcp.financesIngest;
  worker = c.systemd.services.homelab-mcp-finances-ingest;
  collector = c.systemd.services.finance-ingest-metrics;
  secret = c.sops.secrets."homelab-mcp/ingest-env";
  rules = c.modules.alerting.rules;
  checks = {
    ownership-and-quota-are-explicit =
      cfg.enable && cfg.ownershipConfirmed && cfg.timer.enable && cfg.minimumIntervalSeconds == 86400;
    eligibility-is-not-a-bank-pull =
      (worker.serviceConfig.ExecCondition or "")
      == "${c.services.homelab-mcp.package}/bin/homelab-finances-ingest due"
      &&
      worker.serviceConfig.ExecStart
      == "${c.services.homelab-mcp.package}/bin/homelab-finances-ingest run --allow-bank-sync --distinguish-degraded"
      && worker.serviceConfig.Restart == "no"
      && worker.wantedBy == [ ];
    timer-is-persistent-and-quarter-hourly =
      c.systemd.timers.homelab-mcp-finances-ingest.timerConfig.OnCalendar == "*-*-* *:00/15:00 UTC"
      && c.systemd.timers.homelab-mcp-finances-ingest.timerConfig.Persistent
      && c.systemd.timers.homelab-mcp-finances-ingest.wantedBy == [ "timers.target" ];
    canonical-state-and-backend-identity-are-preserved =
      worker.environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH
      == "/var/lib/homelab-mcp/finances-ingest/state.json"
      && worker.serviceConfig.StateDirectory == "homelab-mcp/finances-ingest"
      && worker.serviceConfig.StateDirectoryMode == "0700"
      && worker.serviceConfig.UMask == "0077"
      && worker.serviceConfig.User == c.systemd.services.homelab-mcp.serviceConfig.User
      && collector.serviceConfig.User == worker.serviceConfig.User
      && collector.serviceConfig.Group == worker.serviceConfig.Group;
    token-file-is-dedicated-and-root-managed =
      cfg.environmentFile == secret.path
      && secret.owner == "root"
      && secret.group == "root"
      && secret.mode == "0400"
      && worker.serviceConfig.EnvironmentFile == [ secret.path ]
      && cfg.environmentFile != c.services.homelab-mcp.environmentFile;
    partial-reports-do-not-trigger-generic-systemd-outages =
      worker.serviceConfig.SuccessExitStatus == [ 3 ]
      && rules.finance-ingest-bank-attention.severity == "low"
      && rules.finance-ingest-pipeline-failed.severity == "high"
      && rules.finance-ingest-worker-failed.severity == "high";
    storage-cannot-fall-back-to-root =
      lib.all
        (
          unit:
          unit.unitConfig.RequiresMountsFor == [ "/var/lib/homelab-mcp" ]
          && unit.unitConfig.AssertPathIsMountPoint == [ "/var/lib/homelab-mcp" ]
          && builtins.elem "zfs-service-datasets.service" unit.requires
          && builtins.elem "zfs-service-datasets.service" unit.after
        )
        [
          worker
          collector
        ];
    backup-custody-is-reused =
      c.modules.storage.datasets.services.homelab-mcp.mountpoint == "/var/lib/homelab-mcp"
      && c.modules.storage.datasets.services.homelab-mcp.mode == "0700"
      && c.modules.services.backup.restic.jobs.homelab-mcp.enable
      && c.modules.services.backup.restic.jobs.homelab-mcp-offsite.enable;
    collector-has-no-http-credentials-or-worker-dependency =
      collector.serviceConfig.PrivateNetwork
      && collector.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ]
      && (collector.serviceConfig.EnvironmentFile or [ ]) == [ ]
      && !(collector.environment ? HOMELAB_MCP_FINANCES_SIDECAR_TOKEN)
      && !(collector.environment ? HOMELAB_MCP_FINANCES_INGEST_ENABLED)
      && (collector.serviceConfig.StateDirectory or "") == ""
      && collector.requires == [ "zfs-service-datasets.service" ]
      && !(builtins.elem "homelab-mcp.service" worker.requires);
    collector-cannot-write-state-or-other-metrics =
      collector.environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH
      == worker.environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH
      && collector.serviceConfig.ReadOnlyPaths == [ "/var/lib/homelab-mcp" ]
      && collector.serviceConfig.ReadWritePaths == [ "/run/finance-ingest-metrics" ]
      && collector.serviceConfig.UMask == "0027"
      && collector.serviceConfig.ProtectSystem == "strict"
      && !(builtins.elem "node-exporter" c.users.users.homelab-mcp.extraGroups)
      && builtins.elem "d /run/finance-ingest-metrics 2750 homelab-mcp node-exporter -" c.systemd.tmpfiles.rules
      && builtins.elem "L+ ${c.modules.monitoring.nodeExporter.textfileCollector.directory}/finance_ingest.prom - - - - /run/finance-ingest-metrics/finance_ingest.prom" c.systemd.tmpfiles.rules;
    independent-collection-is-bounded =
      c.systemd.timers.finance-ingest-metrics.timerConfig.OnUnitActiveSec == "2m"
      && c.systemd.timers.finance-ingest-metrics.wantedBy == [ "timers.target" ]
      && collector.serviceConfig.TimeoutStartSec == "60s"
      && collector.serviceConfig.Restart == "no";
    collector-failure-staleness-and-timer-loss-are-high =
      lib.all (name: rules.${name}.severity == "high")
        [
          "finance-ingest-collector-failed"
          "finance-ingest-collector-stale"
          "finance-ingest-timer-stopped"
          "finance-ingest-outcome-unknown"
          "finance-ingest-overdue"
        ];
    export-policy-is-unchanged =
      c.services.homelab-mcp.financesExport.onCalendar == "*-*-* 05:30:00 America/New_York"
      && !(worker.unitConfig ? OnSuccess)
      && !(worker.serviceConfig ? ExecStartPost);
    activation-contract-is-satisfied = lib.all
      (
        a: a.assertion || !(lib.hasPrefix "finance-ingestion" a.message)
      )
      c.assertions;
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg
  (
    failed == [ ]
  ) "Finance ingestion regressions: ${lib.concatStringsSep ", " failed}";
checks
