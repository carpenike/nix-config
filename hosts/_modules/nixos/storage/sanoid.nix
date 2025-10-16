# Sanoid/Syncoid ZFS Snapshot and Replication Management
#
# This module provides declarative ZFS snapshot management using Sanoid and
# remote replication using Syncoid. It coordinates with the backup module
# to ensure snapshot consistency during backups.
#
# FEATURES:
#   - Template-based snapshot retention policies (hourly, daily, weekly, etc.)
#   - Remote replication via Syncoid with SSH key authentication
#   - Pool health monitoring with automated alerting
#   - Pre/post snapshot script execution with validation
#   - Integration with notification system for failure alerts
#
# BACKUP COORDINATION:
#   The backup module (backup.nix) uses ZFS holds to prevent snapshot deletion
#   during active Restic backups. Sanoid respects these holds and will not
#   prune snapshots that are currently held, preventing race conditions.
#
# REPLICATION ARCHITECTURE:
#   - Dedicated zfs-replication user for security isolation
#   - SSH key-based authentication (managed via SOPS)
#   - Per-dataset replication jobs with failure notifications
#   - Automatic retry via systemd on transient failures
#
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
          frequently = lib.mkOption { type = lib.types.int; default = 0; };
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

          # -- Script Hooks --
          preSnapshotScript = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Script to run before taking a snapshot (e.g., pg_backup_start).";
          };

          postSnapshotScript = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Script to run after taking a snapshot (e.g., pg_backup_stop).";
          };

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
      description = ''
        Configuration for datasets to be managed by Sanoid/Syncoid.

        Example configuration:
          modules.backup.sanoid.datasets = {
            "rpool/data/postgresql" = {
              useTemplate = "production";
              processChildrenOnly = true;
              preSnapshotScript = "/run/current-system/sw/bin/pg_backup_start";
              postSnapshotScript = "/run/current-system/sw/bin/pg_backup_stop";
              replication = {
                targetHost = "nas-1.example.com";
                targetUser = "zfs-replication";
                targetDataset = "backup-pool/postgresql";
                sendOptions = "w";  # Raw send for encrypted datasets
                recvOptions = "u";  # Don't mount on target
              };
            };
            "rpool/data/media" = {
              useTemplate = "backup";
              recursive = true;
            };
          };
      '';
    };

    replicationInterval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = ''
        How often to run all Syncoid replication tasks.

        Default is "hourly" for most hosts. For faster DR/lower RPO, override to
        systemd OnCalendar format, e.g., "*:0/15" for every 15 minutes.

        Examples:
          - "hourly" - Once per hour (default)
          - "*:0/15" - Every 15 minutes
          - "*:0/5" - Every 5 minutes
          - "daily" - Once per day
      '';
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
    # -- Validation Assertions --
    assertions = [
      {
        assertion = cfg.sshKeyPath != null -> (lib.any (d: d.replication != null) (lib.attrValues cfg.datasets));
        message = "modules.backup.sanoid: sshKeyPath is configured but no datasets have replication enabled. Either configure replication or remove sshKeyPath.";
      }
      {
        assertion = (lib.any (d: d.replication != null) (lib.attrValues cfg.datasets)) -> cfg.sshKeyPath != null;
        message = "modules.backup.sanoid: Some datasets have replication configured but sshKeyPath is not set. Please configure sshKeyPath for Syncoid authentication.";
      }
      {
        # Fix: useTemplate is a list, so we need to iterate over it and check each template name
        assertion = builtins.all (name:
          let ts = cfg.datasets.${name}.useTemplate;
          in (ts != []) -> builtins.all (t: lib.hasAttr t cfg.templates) ts
        ) (builtins.attrNames cfg.datasets);
        message = "modules.backup.sanoid: Some datasets reference templates that don't exist. All useTemplate references must match defined template names.";
      }
      {
        assertion = builtins.all (name:
          let ds = cfg.datasets.${name};
          in (ds.preSnapshotScript != null -> ds.postSnapshotScript != null)
        ) (builtins.attrNames cfg.datasets);
        message = "modules.backup.sanoid: Datasets with preSnapshotScript should also have postSnapshotScript to ensure cleanup happens. Asymmetric hooks can leave resources in inconsistent state.";
      }
    ];

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
      shell = pkgs.bash;  # Syncoid requires a real shell for SSH operations
      description = "ZFS replication service user";
      # Add to node-exporter group so metrics can be written
      extraGroups = [ "node-exporter" ];
    };
    users.groups.${cfg.replicationGroup} = {};

    # -- Notification Templates --
    modules.notifications.templates = lib.mkIf (config.modules.notifications.enable or false) {
      zfs-replication-failure = {
        enable = true; priority = "high"; title = ''✗ ZFS Replication Failed'';
        body = ''
          <b>Dataset:</b> ''${dataset:-"unknown"}
          <b>Target:</b> ''${targetHost:-"unknown"}
          <b>Error:</b> ''${errorMessage:-"No error details available"}
          <b>Timestamp:</b> $(date -Iseconds)

          <b>Troubleshooting:</b>
          • Check SSH connectivity: ssh ''${targetHost}
          • Review logs: journalctl -u syncoid-*.service
          • Verify SSH key: ls -la /var/lib/zfs-replication/.ssh/
          • Test ZFS send: zfs send -nv ''${dataset}@latest
        '';
      };
      zfs-snapshot-failure = {
        enable = true; priority = "high"; title = ''✗ ZFS Snapshot Failed'';
        body = ''
          <b>Dataset:</b> ''${dataset:-"unknown"}
          <b>Host:</b> ''${hostname:-"unknown"}
          <b>Error:</b> ''${errorMessage:-"No error details available"}
          <b>Timestamp:</b> $(date -Iseconds)

          <b>Troubleshooting:</b>
          • Check ZFS pool health: zpool status
          • Review logs: journalctl -u sanoid.service
          • Verify permissions: zfs allow ''${dataset}
          • Check disk space: df -h /
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
            # NOTE: 'hold' permission removed - syncoid only needs send,snapshot for replication
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
              ${pkgs.zfs}/bin/zfs allow ${cfg.replicationUser} send,snapshot ${lib.escapeShellArg dataset}
            '') datasetsWithReplication)}
            echo "ZFS delegated permissions applied successfully."
          '';
        };
      }
      # Ensure snapdir is visible for Sanoid-managed datasets
      # Only make visible if autosnap is enabled; hide for databases and services that don't need it
      {
        services.zfs-set-snapdir-visible = {
          description = "Set ZFS snapdir visibility for Sanoid datasets";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs-import.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            echo "Setting snapdir visibility for Sanoid datasets..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
              # Only make visible if autosnap is enabled (databases and excluded services get hidden)
              ${pkgs.zfs}/bin/zfs set snapdir=${if (conf.autosnap or false) then "visible" else "hidden"} ${lib.escapeShellArg dataset}
            '') cfg.datasets)}
            echo "snapdir visibility configured successfully."
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
      # Add pre/post snapshot script hooks for datasets that need them
      # SECURITY: Scripts run as sanoid user, not root. Use sudo for privileged operations.
      # If scripts need elevated privileges, configure sudoers with NOPASSWD for specific commands.
      {
        services.sanoid.serviceConfig = let
          datasetsWithPreScript = lib.filterAttrs (name: conf: conf.preSnapshotScript != null) cfg.datasets;
          datasetsWithPostScript = lib.filterAttrs (name: conf: conf.postSnapshotScript != null) cfg.datasets;
        in {
          ExecStartPre = lib.mkIf (datasetsWithPreScript != {}) (
            lib.mkBefore (lib.mapAttrsToList (name: conf:
              # Validate script exists and is executable before running (no root privileges)
              "${pkgs.bash}/bin/bash -c 'test -x ${toString conf.preSnapshotScript} && exec ${toString conf.preSnapshotScript} || { echo \"ERROR: Pre-snapshot script ${toString conf.preSnapshotScript} not found or not executable\" >&2; exit 1; }'"
            ) datasetsWithPreScript)
          );
          ExecStartPost = lib.mkIf (datasetsWithPostScript != {}) (
            lib.mkAfter (lib.mapAttrsToList (name: conf:
              # Validate script exists and is executable before running (no root privileges)
              "${pkgs.bash}/bin/bash -c 'test -x ${toString conf.postSnapshotScript} && exec ${toString conf.postSnapshotScript} || { echo \"ERROR: Post-snapshot script ${toString conf.postSnapshotScript} not found or not executable\" >&2; exit 1; }'"
            ) datasetsWithPostScript)
          );
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
            # Fix CHDIR error by forcing safe working directory
            WorkingDirectory = lib.mkForce "/";
            # Remove conflicting InaccessiblePaths that block the working directory
            InaccessiblePaths = lib.mkForce [];
            # Allow metrics writes to Prometheus textfile collector
            ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];

            BindReadOnlyPaths = lib.mkForce [
              "/nix/store"
              "/etc"
              "/bin/sh"
              "/var/lib/zfs-replication/.ssh"      # Symlink location
              "/run/secrets/zfs-replication"        # SOPS secret directory
            ];
          };

          # Export success/failure metrics for monitoring
          preStart = ''
            mkdir -p /var/lib/node_exporter/textfile_collector
            cat > /var/lib/node_exporter/textfile_collector/syncoid-${sanitizeDatasetName dataset}.prom <<EOF
# HELP syncoid_replication_status Syncoid replication job status (1=success, 0=failed, -1=running)
# TYPE syncoid_replication_status gauge
syncoid_replication_status{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} -1
# HELP syncoid_replication_last_run_timestamp Unix timestamp of last Syncoid run
# TYPE syncoid_replication_last_run_timestamp gauge
syncoid_replication_last_run_timestamp{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} $(date +%s)
EOF
          '';

          postStart = ''
            # Record successful completion
            mkdir -p /var/lib/node_exporter/textfile_collector
            cat > /var/lib/node_exporter/textfile_collector/syncoid-${sanitizeDatasetName dataset}.prom <<EOF
# HELP syncoid_replication_status Syncoid replication job status (1=success, 0=failed, -1=running)
# TYPE syncoid_replication_status gauge
syncoid_replication_status{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} 1
# HELP syncoid_replication_last_success_timestamp Unix timestamp of last successful Syncoid replication
# TYPE syncoid_replication_last_success_timestamp gauge
syncoid_replication_last_success_timestamp{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} $(date +%s)
EOF
          '';

          postStop = ''
            # Check if service failed (exit code != 0)
            if [ "$SERVICE_RESULT" != "success" ]; then
              mkdir -p /var/lib/node_exporter/textfile_collector
              cat > /var/lib/node_exporter/textfile_collector/syncoid-${sanitizeDatasetName dataset}.prom <<EOF
# HELP syncoid_replication_status Syncoid replication job status (1=success, 0=failed, -1=running)
# TYPE syncoid_replication_status gauge
syncoid_replication_status{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} 0
# HELP syncoid_replication_last_failure_timestamp Unix timestamp of last Syncoid failure
# TYPE syncoid_replication_last_failure_timestamp gauge
syncoid_replication_last_failure_timestamp{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} $(date +%s)
EOF
            fi
          '';
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

                echo "[$(date -Iseconds)] Starting ZFS health check on ${config.networking.hostName}"

                for pool in $(${pkgs.zfs}/bin/zpool list -H -o name); do
                  state=$(${pkgs.zfs}/bin/zpool list -H -o health "$pool")

                  if [[ "$state" != "ONLINE" ]]; then
                    status=$(${pkgs.zfs}/bin/zpool status "$pool" 2>&1 || echo "Failed to get pool status")
                    export NOTIFY_POOL="$pool"
                    export NOTIFY_HOSTNAME="${config.networking.hostName}"
                    export NOTIFY_STATE="$state"
                    export NOTIFY_STATUS="$status"
                    ${pkgs.systemd}/bin/systemctl start "notify@pool-degraded:$pool.service"
                    echo "[$(date -Iseconds)] WARNING: Pool $pool is $state - notification sent"

                    # Log health check failure for monitoring
                    echo "zfs_pool_health_check{pool=\"$pool\",state=\"$state\",host=\"${config.networking.hostName}\"} 0" \
                      > /var/lib/node_exporter/textfile_collector/zfs-health-$pool.prom
                  else
                    echo "[$(date -Iseconds)] Pool $pool is ONLINE"

                    # Log successful health check for monitoring
                    echo "zfs_pool_health_check{pool=\"$pool\",state=\"ONLINE\",host=\"${config.networking.hostName}\"} 1" \
                      > /var/lib/node_exporter/textfile_collector/zfs-health-$pool.prom
                  fi
                done

                echo "[$(date -Iseconds)] ZFS health check completed"
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
      # ZFS Hold Garbage Collector
      # Releases stale restic-* holds that weren't cleaned up due to backup failures
      # This prevents disk space exhaustion from accumulated snapshot holds
      {
        services.zfs-hold-gc = {
          description = "Clean up stale ZFS holds from failed backup jobs";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = let
              gcScript = pkgs.writeShellScript "zfs-hold-gc" ''
                set -euo pipefail

                echo "[$(date -Iseconds)] Starting ZFS hold garbage collection on ${config.networking.hostName}"

                # CRITICAL: Skip GC if any restic backup is currently running
                # This prevents releasing holds during long-running backups (>=24h)
                if ${pkgs.systemd}/bin/systemctl list-units --type=service --state=running "restic-backups-*" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "restic-backups-"; then
                  echo "[$(date -Iseconds)] Active restic backup detected; skipping hold GC to avoid releasing in-use holds"
                  exit 0
                fi

                # Find all holds with restic- prefix older than 24 hours
                STALE_HOLD_COUNT=0

                # Iterate through all ZFS snapshots (not datasets - holds are on snapshots)
                ${pkgs.zfs}/bin/zfs list -H -t snapshot -o name | while read -r snapshot; do
                  # Get holds for this snapshot
                  # zfs holds -H output format: FILESYSTEM<TAB>TAG<TAB>TIMESTAMP
                  ${pkgs.zfs}/bin/zfs holds -H "$snapshot" 2>/dev/null \
                  | ${pkgs.gawk}/bin/awk -F "\t" '{print $2 "\t" $3}' \
                  | while IFS=$'\t' read -r tag when; do
                      # Check if hold starts with restic-
                      case "$tag" in
                        restic-*)
                          # Convert creation time to seconds since epoch
                          hold_epoch=$(${pkgs.coreutils}/bin/date -d "$when" +%s 2>/dev/null || echo 0)
                          now=$(${pkgs.coreutils}/bin/date +%s)
                          age_hours=$(( (now - hold_epoch) / 3600 ))

                          # Release holds older than 24 hours
                          if [ "$age_hours" -gt 24 ]; then
                            echo "[$(date -Iseconds)] Releasing stale hold '$tag' on $snapshot (age: $age_hours hours)"
                            if ${pkgs.zfs}/bin/zfs release "$tag" "$snapshot"; then
                              STALE_HOLD_COUNT=$((STALE_HOLD_COUNT + 1))
                            else
                              echo "WARNING: Failed to release hold $tag on $snapshot" >&2
                            fi
                          fi
                          ;;
                      esac
                    done
                done

                # Recompute active restic holds after GC
                ACTIVE_HOLDS=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name \
                  | xargs -r -n1 ${pkgs.zfs}/bin/zfs holds -H 2>/dev/null \
                  | ${pkgs.gnugrep}/bin/grep -c $'^restic-' || echo 0)

                # Export metrics for monitoring (both released count and active hold count)
                mkdir -p /var/lib/node_exporter/textfile_collector
                cat > /var/lib/node_exporter/textfile_collector/zfs-hold-gc.prom <<EOF
# HELP zfs_hold_gc_released_total Number of stale ZFS holds released in last GC run
# TYPE zfs_hold_gc_released_total gauge
zfs_hold_gc_released_total{host="${config.networking.hostName}"} $STALE_HOLD_COUNT
# HELP zfs_active_restic_holds_total Current number of active restic-* holds across all snapshots
# TYPE zfs_active_restic_holds_total gauge
zfs_active_restic_holds_total{host="${config.networking.hostName}"} $ACTIVE_HOLDS
EOF

                if [ "$STALE_HOLD_COUNT" -gt 0 ]; then
                  echo "[$(date -Iseconds)] Released $STALE_HOLD_COUNT stale ZFS holds"
                else
                  echo "[$(date -Iseconds)] No stale holds found"
                fi

                echo "[$(date -Iseconds)] ZFS hold garbage collection completed: $ACTIVE_HOLDS active holds remaining"
              '';
            in "${gcScript}";
          };
        };

        timers.zfs-hold-gc = {
          description = "Daily ZFS hold garbage collection";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };
      }
      # Syncoid replication lag monitoring
      {
        services.zfs-replication-lag-check = lib.mkIf ((datasetsWithReplication != {}) && cfg.healthChecks.enable) {
          description = "Monitor ZFS replication lag for Syncoid datasets";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = let
              checkScript = pkgs.writeShellScript "zfs-replication-lag-check" ''
                set -euo pipefail

                echo "[$(date -Iseconds)] Checking ZFS replication lag"

                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
                  # Get latest local snapshot using locale-independent epoch timestamp
                  LATEST_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name -s creation "${dataset}" | ${pkgs.coreutils}/bin/tail -n 1 || echo "")

                  if [ -n "$LATEST_SNAPSHOT" ]; then
                    # Use -p flag for parseable (numeric epoch) format
                    LATEST_LOCAL_TIME=$(${pkgs.zfs}/bin/zfs get -H -p -o value creation "$LATEST_SNAPSHOT" 2>/dev/null || echo 0)
                  else
                    LATEST_LOCAL_TIME=0
                  fi

                  # Calculate lag in seconds (time since last snapshot)
                  NOW=$(${pkgs.coreutils}/bin/date +%s)
                  LAG_SECONDS=$((NOW - LATEST_LOCAL_TIME))
                  LAG_HOURS=$((LAG_SECONDS / 3600))

                  echo "[$(date -Iseconds)] Dataset ${dataset}: Last snapshot $LAG_HOURS hours ago"

                  # Export metric for Prometheus
                  cat > /var/lib/node_exporter/textfile_collector/zfs-replication-lag-${sanitizeDatasetName dataset}.prom <<EOF
# HELP zfs_replication_lag_seconds Time since last snapshot was created (source-side lag indicator)
# TYPE zfs_replication_lag_seconds gauge
zfs_replication_lag_seconds{dataset="${dataset}",target_host="${conf.replication.targetHost}",host="${config.networking.hostName}"} $LAG_SECONDS
EOF

                  # Warn if lag exceeds 24 hours
                  if [ "$LAG_HOURS" -gt 24 ]; then
                    echo "[$(date -Iseconds)] WARNING: Replication lag for ${dataset} exceeds 24 hours"
                  fi
                '') datasetsWithReplication)}

                echo "[$(date -Iseconds)] Replication lag check completed"
              '';
            in "${checkScript}";
          };
        };

        timers.zfs-replication-lag-check = lib.mkIf ((datasetsWithReplication != {}) && cfg.healthChecks.enable) {
          description = "Periodic ZFS replication lag monitoring";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitActiveSec = "1h";  # Check every hour
            Unit = "zfs-replication-lag-check.service";
          };
        };
      }
    ]);
  };
}
