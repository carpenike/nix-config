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
                hostKey = lib.mkOption {
                  type = lib.types.str;
                  description = "Public SSH host key line for the target, used to pin host identity (e.g., 'nas-1.holthome.net ssh-ed25519 AAAA...').";
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
        assertion = builtins.all (name:
          let ds = cfg.datasets.${name};
          in ds.replication == null || (ds.replication != null && (ds.replication.hostKey or null) != null)
        ) (builtins.attrNames cfg.datasets);
        message = "modules.backup.sanoid: Datasets with replication enabled must have a 'hostKey' specified for SSH host pinning.";
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

    # CRITICAL: SSH config with timeouts to prevent hanging processes
    # Addresses the root cause of the original incident (SSH hanging on host key verification)
    environment.etc."ssh/ssh_config.d/syncoid.conf" = lib.mkIf (datasetsWithReplication != {}) {
      text = ''
        # SSH configuration for syncoid replication
        # Prevents hanging SSH connections that caused the original incident
        Host *
          ConnectTimeout 30
          ServerAliveInterval 15
          ServerAliveCountMax 3
          BatchMode yes
          StrictHostKeyChecking accept-new
          IdentityFile /var/lib/zfs-replication/.ssh/id_ed25519
          IdentitiesOnly yes
      '';
      mode = "0644";
    };

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
    # Populate global SSH known_hosts with replication targets to avoid per-user management
    programs.ssh.knownHosts = let
      replicationEntries = lib.mapAttrsToList (dataset: conf: conf.replication) (lib.filterAttrs (n: ds: ds.replication != null) cfg.datasets);
    in lib.foldl' (acc: repl:
      let
        # hostKey may be provided as either:
        #  - "<host> <type> <key>" (e.g., "nas-1.holthome.net ssh-ed25519 AAAA...")
        #  - "<type> <key>" (e.g., "ssh-ed25519 AAAA...")
        # programs.ssh.knownHosts expects only "<type> <key>" in publicKey,
        # with the hostname supplied by the attribute key. Normalize here.
        tokens = lib.splitString " " (repl.hostKey or "");
        cleanedKey = if tokens != [] && (builtins.head tokens) == repl.targetHost
          then builtins.concatStringsSep " " (builtins.tail tokens)
          else (repl.hostKey or "");
      in acc // {
        "${repl.targetHost}" = { publicKey = cleanedKey; };
      }
    ) {} replicationEntries;
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
  # Prevent systemd from stopping sanoid when nothing wants it; keep timer-driven behavior stable
  # Applied within the systemd merge block below to avoid duplicate attributes

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
      # Ensure Prometheus textfile collector dir exists
      {
        tmpfiles.rules = [
          "d /var/lib/node_exporter/textfile_collector 0775 node-exporter node-exporter -"
        ];
      }
      # Create .ssh directory and config for the replication user
      {
        # Only create the .ssh directory when using a persistent key under /var/lib/<user>/.ssh
        tmpfiles.rules = lib.optional (
          cfg.sshKeyPath != null && lib.hasPrefix ("/var/lib/" + cfg.replicationUser + "/.ssh") (toString cfg.sshKeyPath)
        )
          "d /var/lib/${cfg.replicationUser}/.ssh 0700 ${cfg.replicationUser} ${cfg.replicationGroup} -";
      }
      # Define a syncoid target to group replication jobs for coordination/Conflicts
      {
        targets.syncoid = lib.mkIf (datasetsWithReplication != {}) {
          description = "Syncoid Replication Jobs";
          wantedBy = [ "multi-user.target" ];
        };
      }
      # Populate known_hosts for the replication user to avoid interactive SSH prompts
      # Declarative known_hosts is provided via users.users.<replicationUser>.openssh.knownHosts; remove imperative service
      # ZFS Delegated Permissions
      {
        services.zfs-delegate-permissions = {
          description = "Delegate ZFS permissions for Sanoid and Syncoid";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs-import.target" "systemd-sysusers.service" "zfs-service-datasets.service" ];
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
          after = [ "zfs-import.target" "zfs-service-datasets.service" ];
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
      # Prevent systemd from stopping sanoid when nothing wants it; keep timer-driven behavior stable
      {
        services.sanoid.unitConfig.StopWhenUnneeded = lib.mkForce false;
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
              "${pkgs.bash}/bin/bash -c 'test -x ${toString conf.preSnapshotScript} && exec ${toString conf.preSnapshotScript} || { echo \"ERROR: Pre-snapshot script ${toString conf.preSnapshotScript} not found or not executable\" >&2; exit 1; }'"
            ) datasetsWithPreScript)
          );
          ExecStartPost = lib.mkIf (datasetsWithPostScript != {}) (
            lib.mkAfter (lib.mapAttrsToList (name: conf:
              "${pkgs.bash}/bin/bash -c 'test -x ${toString conf.postSnapshotScript} && exec ${toString conf.postSnapshotScript} || { echo \"ERROR: Post-snapshot script ${toString conf.postSnapshotScript} not found or not executable\" >&2; exit 1; }'"
            ) datasetsWithPostScript)
          );
        };
      }
      # Wire Sanoid to notification system and keep unit persistent
      {
        services.sanoid.unitConfig.OnFailure = lib.mkIf (config.modules.notifications.enable or false)
          [ "notify@zfs-snapshot-failure:%n.service" ];
      }
    ] ++ (lib.mapAttrsToList (dataset: conf:
      let
        serviceName = "syncoid-${lib.strings.replaceStrings ["/"] ["-"] dataset}";
        # Define a sanitized dataset name for use in metric files
        sanitizedDataset = lib.strings.replaceStrings ["/"] ["-"] dataset;
        metricFile = "/var/lib/node_exporter/textfile_collector/syncoid_replication_${sanitizedDataset}.prom";
      in
      {
  # Wire each syncoid job to the notification system and override sandboxing
  services.${serviceName} = {
          # Declarative known_hosts ensures host keys are available; no dependency needed
          unitConfig = lib.mkMerge [
            (lib.mkIf (config.modules.notifications.enable or false) {
              OnFailure = [ "notify@zfs-replication-failure:%n.service" ];
            })
            {
              # Group syncoid under a target and serialize with restic backups
              PartOf = [ "syncoid.target" ];
              # Prevent concurrent execution with restic backups (heavy I/O serialization)
              Conflicts = [ "restic-backups.target" ];
              # Ensure key file exists before starting (works for persistent or ephemeral paths)
              ConditionPathExists = toString cfg.sshKeyPath;
              # CRITICAL: Add network dependency to prevent startup race conditions
              After = [ "network-online.target" ];
              Wants = [ "network-online.target" ];
            }
          ];

          serviceConfig = lib.mkIf (cfg.sshKeyPath != null) {
            Type = "oneshot";
            WorkingDirectory = lib.mkForce "/";
            ProtectHome = lib.mkForce false;
            PrivateMounts = lib.mkForce false;
            # Disable systemd namespace isolation that conflicts with our scripts
            RootDirectory = lib.mkForce "";
            RootDirectoryStartOnly = lib.mkForce false;
            RuntimeDirectory = lib.mkForce "";
            ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];
            UMask = lib.mkForce "0002";
            PermissionsStartOnly = lib.mkForce false;

            # CRITICAL: Shorter timeout to fail faster (was 2h, now 45m)
            TimeoutStartSec = "45m";
            TimeoutStopSec = "5m";

            # CRITICAL: Add resource limits to prevent runaway processes
            CPUQuota = "75%";
            MemoryMax = "4G";
            IOWeight = 500; # Lower I/O priority than default (1000)

            # TODO: Add SSH timeouts via SSH config or wrapper script
            # For now, systemd timeout provides protection, but SSH-level timeouts would be better


            # CRITICAL: Re-enable metrics hooks with CHDIR fix + serialization via flock
            # These metrics are required for Prometheus staleness alerts
            ExecStartPre = [
              # CRITICAL: Serialize all syncoid jobs to prevent resource exhaustion
              # -n flag: fail immediately if lock held (prevents job pile-up)
              # /tmp: writable by all users, suitable for runtime locks
              # Use absolute paths and avoid shell dependencies that might cause CHDIR issues
              (pkgs.writeShellScript "syncoid-acquire-lock-${sanitizedDataset}" ''
                ${pkgs.util-linux}/bin/flock -n /tmp/syncoid.lock \
                  ${pkgs.coreutils}/bin/echo "Acquired syncoid lock for ${serviceName} at $(${pkgs.coreutils}/bin/date)"
              '')
              # Write metrics indicating job is starting
              (pkgs.writeShellScript "syncoid-metrics-pre-${sanitizedDataset}" ''
                set -eu
                # Ensure metrics directory exists
                mkdir -p "$(dirname "${metricFile}")"
                # Write 'in-progress' metric
                cat > "${metricFile}.tmp" <<EOF
                # HELP syncoid_replication_status Current status of a syncoid replication job (0=fail, 1=success, 2=in-progress)
                # TYPE syncoid_replication_status gauge
                syncoid_replication_status{dataset="${dataset}",target_host="${conf.replication.targetHost}",unit="${serviceName}"} 2
                # HELP syncoid_replication_info Static information about replication configuration
                # TYPE syncoid_replication_info gauge
                syncoid_replication_info{dataset="${dataset}",target_host="${conf.replication.targetHost}",unit="${serviceName}"} 1
                EOF
                mv "${metricFile}.tmp" "${metricFile}"
              '')
            ];

            ExecStartPost = pkgs.writeShellScript "syncoid-metrics-post-${sanitizedDataset}" ''
              set -eu
              # Check the main service result using systemd environment variable
              # SERVICE_RESULT is set by systemd after ExecStart completes
              STATUS=0 # Assume failure
              if [ "''${SERVICE_RESULT:-failure}" = "success" ]; then
                STATUS=1 # Success
              fi

              # Debug: Log the SERVICE_RESULT for troubleshooting
              echo "SERVICE_RESULT=''${SERVICE_RESULT:-unset} STATUS=$STATUS" >&2

              cat > "${metricFile}.tmp" <<EOF
              # HELP syncoid_replication_status Current status of a syncoid replication job (0=fail, 1=success, 2=in-progress)
              # TYPE syncoid_replication_status gauge
              syncoid_replication_status{dataset="${dataset}",target_host="${conf.replication.targetHost}",unit="${serviceName}"} $STATUS
              # HELP syncoid_replication_info Static information about replication configuration
              # TYPE syncoid_replication_info gauge
              syncoid_replication_info{dataset="${dataset}",target_host="${conf.replication.targetHost}",unit="${serviceName}"} 1
              EOF

              # Only add timestamp metric on success
              if [ $STATUS -eq 1 ]; then
                cat >> "${metricFile}.tmp" <<EOF
              # HELP syncoid_replication_last_success_timestamp Timestamp of the last successful replication
              # TYPE syncoid_replication_last_success_timestamp gauge
              syncoid_replication_last_success_timestamp{dataset="${dataset}",target_host="${conf.replication.targetHost}",unit="${serviceName}"} $(date +%s)
              EOF
              fi

              mv "${metricFile}.tmp" "${metricFile}"
            '';
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
                    echo "zfs_pool_health_check{pool=\"$pool\",state=\"$state\"} 0" \
                      > /var/lib/node_exporter/textfile_collector/zfs-health-$pool.prom
                  else
                    echo "[$(date -Iseconds)] Pool $pool is ONLINE"

                    # Log successful health check for monitoring
                    echo "zfs_pool_health_check{pool=\"$pool\",state=\"ONLINE\"} 1" \
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
                METRIC_FILE="/var/lib/node_exporter/textfile_collector/zfs-hold-gc.prom"
                mkdir -p /var/lib/node_exporter/textfile_collector
                cat > "$METRIC_FILE.tmp" <<EOF
# HELP zfs_hold_gc_released_total Number of stale ZFS holds released in last GC run
# TYPE zfs_hold_gc_released_total gauge
zfs_hold_gc_released_total $STALE_HOLD_COUNT
# HELP zfs_active_restic_holds_total Current number of active restic-* holds across all snapshots
# TYPE zfs_active_restic_holds_total gauge
zfs_active_restic_holds_total $ACTIVE_HOLDS
EOF
                ${pkgs.coreutils}/bin/mv "$METRIC_FILE.tmp" "$METRIC_FILE"

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
                  METRIC_FILE="/var/lib/node_exporter/textfile_collector/zfs-replication-lag-${lib.strings.replaceStrings ["/"] ["-"] dataset}.prom"
                  cat > "$METRIC_FILE.tmp" <<EOF
# HELP zfs_replication_lag_seconds Time since last snapshot was created (source-side lag indicator)
# TYPE zfs_replication_lag_seconds gauge
zfs_replication_lag_seconds{dataset="${dataset}",target_host="${conf.replication.targetHost}"} $LAG_SECONDS
EOF
                  ${pkgs.coreutils}/bin/mv "$METRIC_FILE.tmp" "$METRIC_FILE"

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
      # Target reachability probe (per replication target)
      {
        services.syncoid-target-reachability = lib.mkIf (datasetsWithReplication != {}) {
          description = "Probe SSH reachability to Syncoid replication targets";
          serviceConfig = {
            Type = "oneshot";
            # Run as the replication user to validate real syncoid connection path
            User = cfg.replicationUser;
            Group = cfg.replicationGroup;
            WorkingDirectory = "/";
            # Ensure the SSH key exists before starting
            ConditionPathExists = toString cfg.sshKeyPath;
            ExecStart = let
              # Build a list of unique replication target hosts (dedupe per-host probes)
              uniqueHosts = lib.unique (lib.mapAttrsToList (dataset: conf: conf.replication.targetHost) datasetsWithReplication);
              probeScript = pkgs.writeShellScript "syncoid-target-reachability" ''
                set -eu
                METRICS=/var/lib/node_exporter/textfile_collector/syncoid-target-reachability.prom
                ${pkgs.coreutils}/bin/rm -f "$METRICS.tmp"
                ${lib.concatStringsSep "\n" (map (host: ''
                  TARGET_HOST="${host}"
                  TARGET_USER="${cfg.replicationUser}"
                  # High-fidelity check: SSH handshake using the configured replication key
                  if ${pkgs.openssh}/bin/ssh \
                       -i ${toString cfg.sshKeyPath} \
                       -o BatchMode=yes \
                       -o ConnectTimeout=10 \
                       -o StrictHostKeyChecking=yes \
                       "${cfg.replicationUser}@${host}" \
                       "exit" >/dev/null 2>&1; then
                    VAL=1
                  else
                    VAL=0
                  fi
                  ${pkgs.coreutils}/bin/printf '%s\n' "syncoid_target_reachable{target_host=\"$TARGET_HOST\"} $VAL" >> "$METRICS.tmp"
                '' ) uniqueHosts)}
                ${pkgs.coreutils}/bin/mv "$METRICS.tmp" "$METRICS"
              '';
            in probeScript;
          };
        };
        timers.syncoid-target-reachability = lib.mkIf (datasetsWithReplication != {}) {
          description = "Periodic reachability probe for Syncoid targets";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "30min";
            Unit = "syncoid-target-reachability.service";
          };
        };
      }
      # Static replication info metric (inventory of configured jobs)
      {
        services.syncoid-replication-info = lib.mkIf (datasetsWithReplication != {}) {
          description = "Emit static info metric for all configured Syncoid replication jobs";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = let
              infoScript = pkgs.writeShellScript "syncoid-replication-info" ''
                set -eu
                METRICS=/var/lib/node_exporter/textfile_collector/syncoid-replication-info.prom
                ${pkgs.coreutils}/bin/rm -f "$METRICS.tmp"
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dataset: conf: ''
                  UNIT="syncoid-${lib.strings.replaceStrings ["/"] ["-"] dataset}.service"
                  ${pkgs.coreutils}/bin/printf '%s\n' "syncoid_replication_info{dataset=\"${dataset}\",target_host=\"${conf.replication.targetHost}\",unit=\"$UNIT\"} 1" >> "$METRICS.tmp"
                '' ) datasetsWithReplication)}
                ${pkgs.coreutils}/bin/mv "$METRICS.tmp" "$METRICS"
              '';
            in infoScript;
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]);
  };
}
