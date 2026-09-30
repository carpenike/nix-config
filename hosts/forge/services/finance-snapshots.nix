{ config, lib, pkgs, ... }:
let
  app = config.services.homelab-mcp;
  exporter = config.systemd.services.homelab-mcp-finances-export;
  worker = "homelab-mcp-finances-snapshot";
  dataDir = "/var/lib/homelab-mcp";
  statePath = "${dataDir}/finances-ingest/state.json";
  metricsDir = "/run/finance-snapshot-metrics";
  textfileDir = config.modules.monitoring.nodeExporter.textfileCollector.directory;
in
{
  assertions = [
    {
      assertion = app.enable && app.financesExport.enable && app.financesIngest.enable
        && lib.versionAtLeast (app.package.version or "0") "0.32.0";
      message = "finance-snapshots requires the paired MCP >= 0.32.0 export CLI with --after-ingestion --json; do not activate with the old pin.";
    }
    {
      assertion = exporter.serviceConfig.User == "homelab-mcp"
        && exporter.serviceConfig.Group == "homelab-mcp"
        && builtins.elem dataDir exporter.serviceConfig.ReadOnlyPaths
        && config.systemd.services.homelab-mcp-finances-ingest.environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH == statePath;
      message = "finance-snapshots must reuse the exporter identity and read-only canonical ingestion state.";
    }
    {
      assertion = config.modules.monitoring.nodeExporter.enable
        && config.modules.monitoring.nodeExporter.textfileCollector.enable
        && builtins.elem "systemd" config.services.prometheus.exporters.node.enabledCollectors;
      message = "finance-snapshots requires node-exporter textfile and systemd collectors.";
    }
  ];

  # Same setgid/flat-link pattern as ingestion: only this aggregate file is
  # readable by node-exporter; neither service gains another writer's directory.
  systemd.tmpfiles.rules = [
    "d ${metricsDir} 2750 ${exporter.serviceConfig.User} node-exporter -"
    "L+ ${textfileDir}/finance_snapshot.prom - - - - ${metricsDir}/finance_snapshot.prom"
  ];

  systemd.services.${worker} = {
    description = "Publish a finance snapshot after a completed ingestion";
    after = lib.unique (exporter.after ++ [
      "zfs-service-datasets.service"
      "systemd-tmpfiles-setup.service"
    ]);
    requires = lib.unique (exporter.requires ++ [ "zfs-service-datasets.service" ]);
    wants = exporter.wants;
    unitConfig = {
      RequiresMountsFor = [ dataDir ];
      AssertPathIsMountPoint = [ dataDir ];
    };
    # Inherit the EFFECTIVE unit settings, including host-added floors/DSNs
    # and EnvironmentFiles, rather than reconstructing upstream defaults.
    environment = exporter.environment;
    serviceConfig = {
      inherit (exporter.serviceConfig)
        User Group EnvironmentFile ReadOnlyPaths
        ProtectSystem ProtectHome PrivateTmp PrivateDevices
        ProtectKernelTunables ProtectKernelModules ProtectControlGroups
        NoNewPrivileges RestrictRealtime RestrictSUIDSGID LockPersonality
        MemoryDenyWriteExecute SystemCallFilter CapabilityBoundingSet
        RestrictAddressFamilies MemoryMax CPUQuota TasksMax;
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${./finance-snapshots/collect.py} --exporter ${app.package}/bin/homelab-finances-export --ingestion-state ${statePath} --metrics-file ${metricsDir}/finance_snapshot.prom --timeout 210";
      ReadWritePaths = [ metricsDir ];
      UMask = "0027";
      TimeoutStartSec = "240s";
      TimeoutStopSec = "10s";
      KillMode = "control-group";
      Restart = "no";
      # No StateDirectory: this reader must never initialize/chmod bank state.
    };
  };

  # A oneshot cannot overlap itself. The CLI serializes projection writers
  # (including the unchanged nightly export) with the shared PostgreSQL lock.
  systemd.timers.${worker} = {
    description = "Check for an unpublished finance ingestion every five minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "5m";
      AccuracySec = "10s";
      Unit = "${worker}.service";
    };
  };

  modules.alerting.rules = import ./finance-snapshots/alerts.nix {
    inherit worker;
    host = config.networking.hostName;
  };
}
