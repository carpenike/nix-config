{ lib, config, pkgs, ... }:

let
  cfg = config.modules.backup.sanoid;

  # Helper to create a valid systemd service name from a ZFS dataset path
  # This mimics the logic within the NixOS syncoid module.
  sanitizeDatasetName = dataset: lib.strings.replaceStrings [ "/" ] [ "-" ] dataset;

  # Get datasets that have replication configured
  datasetsWithReplication = lib.filterAttrs (name: conf: conf.replication != null) cfg.datasets;

in
{
  options.modules.backup.sanoid = {
    enable = lib.mkEnableOption "Sanoid/Syncoid for ZFS snapshots and replication";

    # -- User Configuration --
    replicationUser = lib.mkOption {
      type = lib.types.str;
      default = "zfs-replication";
      description = "User account to run Syncoid replication tasks.";
    };

    replicationGroup = lib.mkOption {
      type = lib.types.str;
      default = "zfs-replication";
      description = "Group for the Syncoid replication user.";
    };

    sshKeyPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/zfs-replication/.ssh/id_ed25519";
      description = "Absolute path to the SSH private key for Syncoid. Should be managed by SOPS.";
    };

    # -- Sanoid Configuration --
    templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          minutely = lib.mkOption { type = lib.types.int; default = 0; };
          hourly = lib.mkOption { type = lib.types.int; default = 0; };
          daily = lib.mkOption { type = lib.types.int; default = 0; };
          weekly = lib.mkOption { type = lib.types.int; default = 0; };
          monthly = lib.mkOption { type = lib.types.int; default = 0; };
          yearly = lib.mkOption { type = lib.types.int; default = 0; };
          autosnap = lib.mkOption { type = lib.types.bool; default = true; };
          autoprune = lib.mkOption { type = lib.types.bool; default = true; };
        };
      });
      default = {};
      description = "Sanoid templates for reusable snapshot retention policies.";
    };

    datasets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          # -- Snapshotting Options --
          recursive = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create snapshots for child datasets recursively.";
          };

          useTemplate = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "List of Sanoid templates to apply.";
          };

          retention = lib.mkOption {
            type = lib.types.attrsOf lib.types.int;
            default = {};
            description = "Inline snapshot retention policy.";
            example = { hourly = 24; daily = 7; };
          };

          autosnap = lib.mkOption { type = lib.types.bool; default = true; };
          autoprune = lib.mkOption { type = lib.types.bool; default = true; };

          # -- Replication Options --
          replication = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                targetHost = lib.mkOption {
                  type = lib.types.str;
                  description = "Hostname of the replication target.";
                };
                targetUser = lib.mkOption {
                  type = lib.types.str;
                  default = cfg.replicationUser;
                  description = "User on the target host to connect as.";
                };
                targetDataset = lib.mkOption {
                  type = lib.types.str;
                  description = "Full path to the target ZFS dataset on the remote host.";
                };
                sendOptions = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Syncoid send options (e.g., 'w' for raw encrypted).";
                };
                recvOptions = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Syncoid receive options (e.g., 'u' for no mount).";
                };
              };
            });
            default = null;
            description = "Configuration for replicating this dataset via Syncoid.";
          };
        };
      });
      default = {};
      description = "Configuration for datasets to be managed by Sanoid/Syncoid.";
    };

    replicationInterval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "How often to run all Syncoid replication tasks.";
    };

    snapshotInterval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "How often to run Sanoid snapshot creation (systemd OnCalendar format). Use '*:0/5' for every 5 minutes.";
    };

    # -- Health Check Configuration --
    healthChecks = {
      enable = lib.mkEnableOption "ZFS pool health checks";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "15min";
        description = "Frequency of ZFS pool health checks.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # -- User and Group Management --
    users.users.sanoid = {
      isSystemUser = true;
      group = "sanoid";
      description = "Sanoid ZFS snapshot management user";
    };
    users.groups.sanoid = {};

    users.users.${cfg.replicationUser} = {
      isSystemUser = true;
      group = cfg.replicationGroup;
      home = "/var/lib/${cfg.replicationUser}";
      createHome = true;
      shell = "/run/current-system/sw/bin/nologin";
      description = "ZFS replication service user";
    };
    users.groups.${cfg.replicationGroup} = {};

    # -- Notification Templates --
    modules.notifications.templates = lib.mkIf (config.modules.notifications.enable or false) {
      zfs-replication-failure = {
        enable = true; priority = "high"; title = ''✗ ZFS Replication Failed'';
        body = ''
          <b>Dataset:</b> ''${dataset}
          <b>Target:</b> ''${targetHost}
          <b>Error:</b> ''${errorMessage}
        '';
      };
      zfs-snapshot-failure = {
        enable = true; priority = "high"; title = ''✗ ZFS Snapshot Failed'';
        body = ''
          <b>Dataset:</b> ''${dataset}
          <b>Host:</b> ''${hostname}
          <b>Error:</b> ''${errorMessage}
        '';
      };
      pool-degraded = {
        enable = true; priority = "emergency"; title = ''🚨 URGENT: ZFS Pool Degraded'';
        body = ''
          <b>Pool:</b> ''${pool}
          <b>Host:</b> ''${hostname}
          <b>State:</b> <font color="red">''${state}</font>
          <b>Pool Status:</b>
          ''${status}
        '';
      };
    };

    # -- ZFS Delegated Permissions Service --
    # This is configured as a standalone systemd service outside the merged block

    # -- Sanoid Service Configuration --
    services.sanoid = {
      enable = true;
      interval = cfg.snapshotInterval;
      templates = cfg.templates;
      datasets = lib.mapAttrs (name: conf: {
        inherit (conf) recursive useTemplate autosnap autoprune;
      } // conf.retention) cfg.datasets;
    };

    # -- Syncoid Service Configuration --
    services.syncoid = lib.mkIf (datasetsWithReplication != {}) {
      enable = true;
      interval = cfg.replicationInterval;
      user = cfg.replicationUser;
      group = cfg.replicationGroup;
      sshKey = cfg.sshKeyPath;

      commands = lib.mapAttrs (
        name: conf: {
          target = "${conf.replication.targetUser}@${conf.replication.targetHost}:${conf.replication.targetDataset}";
          recursive = conf.recursive; # Inherit recursiveness from snapshot config
          inherit (conf.replication) sendOptions recvOptions;
        }
      ) datasetsWithReplication;
    };

    # -- Systemd Configuration (Sanoid, Syncoid, Health Checks) --
    systemd = lib.mkMerge ([
      # Create .ssh directory for the replication user
      {
        tmpfiles.rules = lib.optional (cfg.sshKeyPath != null)
          "d /var/lib/${cfg.replicationUser}/.ssh 0700 ${cfg.replicationUser} ${cfg.replicationGroup} -";
      }
      # ZFS Delegated Permissions
      {
        services.zfs-delegate-permissions = {
          description = "Delegate ZFS permissions for Sanoid and Syncoid";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs-import.target" "systemd-sysusers.service" ];
          before = [ "sanoid.service" ] ++ (lib.optional (datasetsWithReplication != {}) "syncoid.service");
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            echo "Applying ZFS delegated permissions..."
            # Grant permissions for Sanoid to manage snapshots
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
              ${pkgs.zfs}/bin/zfs allow sanoid send,snapshot,hold,destroy ${lib.escapeShellArg dataset}
            '') cfg.datasets)}

            # Grant permissions for Syncoid to send snapshots for replication
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
              ${pkgs.zfs}/bin/zfs allow ${cfg.replicationUser} send,snapshot,hold ${lib.escapeShellArg dataset}
            '') datasetsWithReplication)}
            echo "ZFS delegated permissions applied successfully."
          '';
        };
      }
      # Use a static user for sanoid to allow pre-boot permission delegation
      {
        services.sanoid.serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "sanoid";
          Group = "sanoid";
        };
      }
      # Wire Sanoid to notification system
      {
        services.sanoid.unitConfig.OnFailure = lib.mkIf (config.modules.notifications.enable or false)
          [ "notify@zfs-snapshot-failure:%n.service" ];
      }
    ] ++ (lib.mapAttrsToList (dataset: conf:
      let
        serviceName = "syncoid-${sanitizeDatasetName dataset}";
      in
      {
        # Wire each syncoid job to the notification system and override sandboxing
        services.${serviceName} = {
          unitConfig = lib.mkIf (config.modules.notifications.enable or false) {
            OnFailure = [ "notify@zfs-replication-failure:%n.service" ];
          };

          # Override sandboxing to allow SSH key access, especially for SOPS-managed keys
          # Both the symlink location (/var/lib/zfs-replication/.ssh) and the actual
          # SOPS secret path (/run/secrets/zfs-replication) must be bound for resolution
          serviceConfig = lib.mkIf (cfg.sshKeyPath != null) {
            BindReadOnlyPaths = lib.mkForce [
              "/nix/store"
              "/etc"
              "/bin/sh"
              "/var/lib/zfs-replication/.ssh"      # Symlink location
              "/run/secrets/zfs-replication"        # SOPS secret directory
            ];
          };
        };
      }
    ) datasetsWithReplication) ++ [
      # ZFS Pool Health Monitoring
      {
        services.zfs-health-check = lib.mkIf cfg.healthChecks.enable {
          description = "Check ZFS pool health and notify on degraded state";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = let
              checkScript = pkgs.writeShellScript "zfs-health-check" ''
                set -euo pipefail
                for pool in $(${pkgs.zfs}/bin/zpool list -H -o name); do
                  state=$(${pkgs.zfs}/bin/zpool list -H -o health "$pool")
                  if [[ "$state" != "ONLINE" ]]; then
                    status=$(${pkgs.zfs}/bin/zpool status "$pool" 2>&1 || echo "Failed to get pool status")
                    export NOTIFY_POOL="$pool"
                    export NOTIFY_HOSTNAME="${config.networking.hostName}"
                    export NOTIFY_STATE="$state"
                    export NOTIFY_STATUS="$status"
                    ${pkgs.systemd}/bin/systemctl start "notify@pool-degraded:$pool.service"
                    echo "WARNING: Pool $pool is $state - notification sent"
                  else
                    echo "Pool $pool is ONLINE"
                  fi
                done
              '';
            in "${checkScript}";
          };
        };

        timers.zfs-health-check = lib.mkIf cfg.healthChecks.enable {
          description = "Periodic ZFS pool health check";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = cfg.healthChecks.interval;
            Unit = "zfs-health-check.service";
          };
        };
      }
    ]);
  };
}
