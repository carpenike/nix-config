{ config, lib, ... }:
let
  cfg = config.modules.services.vscode-agent-host;
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  name = "vscode-agent-host";
  dataset = "tank/services/${name}";
in
{
  config = lib.mkMerge [
    {
      modules.services.vscode-agent-host = {
        # Operator-approved manual acceptance. Boot remains gated on RB-12.
        enable = true;
        startAtBoot = false;
        runtimeAccepted = false;
        connectionTokenFile = "/run/secrets/${name}/connection-token";
        workspaces = [ "scratch" ];
        backup = (forgeDefaults.mkBackupWithTags name [ "development" "private" "forge" ]) // {
          excludePatterns = [ "cache" "logs/supervisor.log*" ".vscode-server/cli/agent-host-stable.log*" ];
        };
      };
    }
    (lib.mkIf cfg.enable {
      sops.secrets."${name}/connection-token" = {
        sopsFile = ../secrets.sops.yaml;
        mode = "0400";
      };

      modules.storage.datasets.services.${name} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0700";
        properties.quota = "20G";
        protection = {
          class = "standard";
          objectives = {
            onsiteRpoSeconds = 3600;
            offsiteRpoSeconds = 86400;
            rtoSeconds = 14400;
          };
          requiredTiers = [ "local-snapshot" "replication" "nas-backup" "offsite-backup" ];
          consistency = "crash-consistent";
          validator = null;
          allowEmptyBootstrap = false;
          notes = "Initial bootstrap is operator-only. After state exists, restore before starting; provider reauthentication and session inspection remain operator gates.";
        };
      };
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset name;
      modules.services.backup.restic.jobs."${name}-offsite" = {
        enable = true;
        repository = "r2-offsite";
        paths = [ cfg.dataDir ];
        tags = [ name "development" "private" "offsite" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
        excludePatterns = [ "cache" "logs/supervisor.log*" ".vscode-server/cli/agent-host-stable.log*" ];
      };

      systemd.services.${name} = {
        after = [ "zfs-service-datasets.service" ];
        requires = [ "zfs-service-datasets.service" ];
      };

      modules.alerting.rules = lib.mkIf cfg.startAtBoot {
        "${name}-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert name "VSCodeAgentHost" "standalone coding host";
        "${name}-transport-failed" = {
          type = "promql";
          expr = ''node_systemd_unit_state{name="${name}-healthcheck.service",state="failed"} == 1'';
          # Below the two-minute retry cadence: activating probes briefly clear
          # the failed state and must not reset a longer pending alert forever.
          for = "30s";
          severity = "high";
          labels.service = name;
          annotations = {
            summary = "Agent Host authenticated protocol check failed";
            description = "The process alone is not ready. This check does not certify provider login or token lifetime.";
            command = "systemctl status ${name}-healthcheck.service";
          };
        };
        "${name}-healthcheck-timer-down" = {
          type = "promql";
          expr = ''node_systemd_unit_state{name="${name}-healthcheck.timer",state="active"} == 0'';
          for = "5m";
          severity = "high";
          labels.service = name;
          annotations = {
            summary = "Agent Host independent healthcheck timer is inactive";
            description = "Restore the timer; an active host without protocol probes is not evidence of health.";
            command = "systemctl status ${name}-healthcheck.timer";
          };
        };
      };
    })
  ];
}
