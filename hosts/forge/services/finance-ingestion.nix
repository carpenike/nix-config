{ config
, lib
, pkgs
, ...
}:
let
  app = config.services.homelab-mcp;
  cfg = app.financesIngest;
  worker = "homelab-mcp-finances-ingest";
  collector = "finance-ingest-metrics";
  dataDir = "/var/lib/homelab-mcp";
  statePath = "${dataDir}/finances-ingest/state.json";
  metricsDir = "/run/${collector}";
  textfileDir = config.modules.monitoring.nodeExporter.textfileCollector.directory;
  collect = pkgs.writeShellApplication {
    name = collector;
    runtimeInputs = [
      app.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.prometheus.cli
    ];
    text = builtins.readFile ./finance-ingestion/collect.sh;
  };
in
{
  services.homelab-mcp.financesIngest = {
    enable = true;
    # Ryan confirmed the external 08:30 owner is disabled and approved this
    # eligibility cadence. The existing durable reservation is NOT reset.
    ownershipConfirmed = true;
    environmentFile = config.sops.secrets."homelab-mcp/ingest-env".path;
    minimumIntervalSeconds = 86400;
    timer = {
      enable = true;
      onCalendar = "*-*-* *:00/15:00 UTC";
    };
  };

  # Provision this token-only dotenv and repin the CLI together, before activation.
  sops.secrets."homelab-mcp/ingest-env" = {
    sopsFile = ../secrets.sops.yaml;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  assertions = [
    {
      assertion =
        (config.systemd.services.${worker}.serviceConfig.ExecCondition or "")
        == "${app.package}/bin/homelab-finances-ingest due"
        &&
        config.systemd.services.${worker}.serviceConfig.ExecStart
        == "${app.package}/bin/homelab-finances-ingest run --allow-bank-sync --distinguish-degraded"
        && config.systemd.services.${worker}.serviceConfig.SuccessExitStatus == [ 3 ];
      message = "finance-ingestion requires the MCP pin with due and distinguish-degraded; exit 1 must skip conditions and fail runs.";
    }
    {
      assertion =
        cfg.minimumIntervalSeconds >= 86400
        &&
        config.systemd.services.${worker}.environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH == statePath;
      message = "finance-ingestion must preserve the canonical durable reservation and at least 24 hours between POST attempts.";
    }
    {
      assertion = cfg.environmentFile != app.environmentFile;
      message = "finance-ingestion must not load the MCP/OAuth environment file.";
    }
    {
      assertion =
        config.modules.monitoring.nodeExporter.enable
        && config.modules.monitoring.nodeExporter.textfileCollector.enable
        && builtins.elem "systemd" config.services.prometheus.exporters.node.enabledCollectors;
      message = "finance-ingestion requires node-exporter textfile and systemd collectors.";
    }
    {
      assertion =
        config.modules.storage.datasets.services.homelab-mcp.mountpoint == dataDir
        && config.modules.services.backup.restic.jobs.homelab-mcp.enable
        && config.modules.services.backup.restic.jobs.homelab-mcp-offsite.enable;
      message = "finance-ingestion state must remain on the protected MCP dataset with its existing backups.";
    }
  ];

  systemd.services.${worker} = {
    after = [ "zfs-service-datasets.service" ];
    requires = [ "zfs-service-datasets.service" ];
    unitConfig = {
      RequiresMountsFor = [ dataDir ];
      AssertPathIsMountPoint = [ dataDir ];
    };
  };

  # A flat symlink is visible to node-exporter's non-recursive collector.
  # The writer can only replace its own file, never another service's metrics.
  # setgid gives the reader access without adding MCP to node-exporter's group.
  systemd.tmpfiles.rules = [
    "d ${metricsDir} 2750 homelab-mcp node-exporter -"
    "L+ ${textfileDir}/finance_ingest.prom - - - - ${metricsDir}/finance_ingest.prom"
  ];

  systemd.services.${collector} = {
    description = "Publish read-only finance ingestion state for node-exporter";
    after = [
      "zfs-service-datasets.service"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "zfs-service-datasets.service" ];
    unitConfig = {
      RequiresMountsFor = [ dataDir ];
      AssertPathIsMountPoint = [ dataDir ];
    };
    environment.HOMELAB_MCP_FINANCES_INGEST_STATE_PATH = statePath;
    serviceConfig = {
      Type = "oneshot";
      User = "homelab-mcp";
      Group = "homelab-mcp";
      ExecStart = "${collect}/bin/${collector} ${metricsDir}/finance_ingest.prom";
      TimeoutStartSec = "60s";
      UMask = "0027";
      Restart = "no";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = "";
      ReadOnlyPaths = [ dataDir ];
      InaccessiblePaths = [
        "-/run/secrets"
        "-/run/credentials"
      ];
      ReadWritePaths = [ metricsDir ];
      MemoryMax = "256M";
      TasksMax = 32;
    };
  };

  systemd.timers.${collector} = {
    description = "Collect finance ingestion evidence every two minutes without HTTP";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "2m";
      AccuracySec = "10s";
      Unit = "${collector}.service";
    };
  };

  modules.alerting.rules = import ./finance-ingestion/alerts.nix {
    inherit worker collector;
    host = config.networking.hostName;
    runGraceSeconds = cfg.runTimeoutSeconds + 120;
  };
}
