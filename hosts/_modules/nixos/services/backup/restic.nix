# Unified Restic Backup Management
#
# Handles all Restic backup operations with:
# - Automatic service discovery from backup submodules
# - ZFS snapshot integration for consistency
# - Enterprise monitoring via textfile collector
# - Automated repository management

{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.backup;
  resticCfg = cfg.restic or {};

  # Use centralized job list from default.nix (includes both discovered and manual jobs)
  allJobs = cfg._internal.allJobs;

  # Create systemd service for each backup job
  mkBackupService = jobName: jobConfig:
    let
      repository = cfg.repositories.${jobConfig.repository} or (throw "Repository '${jobConfig.repository}' not found for backup job '${jobName}'. Available repositories: ${toString (lib.attrNames cfg.repositories)}");

      # Build snapshot paths if ZFS snapshots are enabled
      snapshotPaths = if jobConfig.useSnapshots && jobConfig.zfsDataset != null
        then map (path:
          let
            # Replace the original path with snapshot path
            relativePath = lib.removePrefix jobConfig.zfsDataset path;
            snapshotPath = "${jobConfig.zfsDataset}/.zfs/snapshot/backup-${jobName}${relativePath}";
          in snapshotPath
        ) jobConfig.paths
        else jobConfig.paths;

      # Build restic command arguments
      excludeArgs = lib.concatMapStringsSep " " (pattern: "--exclude '${pattern}'") jobConfig.excludePatterns;
      tagArgs = lib.concatMapStringsSep " " (tag: "--tag '${tag}'") jobConfig.tags;
      pathArgs = lib.concatStringsSep " " (map (path: "'${path}'") snapshotPaths);

      # Environment setup
      envVars = [
        "RESTIC_REPOSITORY=${repository.url}"
        "RESTIC_PASSWORD_FILE=${repository.passwordFile}"
        "RESTIC_CACHE_DIR=${cfg.performance.cacheDir}"
      ] ++ lib.optionals (repository.environmentFile != null) [
        # Cloud credentials will be loaded via EnvironmentFile
      ];

    in {
      "restic-backup-${jobName}" = {
        description = "Restic backup for ${jobName}";
        wants = [ "backup.target" ];
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ] ++ lib.optionals jobConfig.useSnapshots [
          "zfs-snapshot-${jobName}.service"
        ];

        serviceConfig = {
          Type = "oneshot";
          User = "restic-backup";
          Group = "restic-backup";

          # Security hardening
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;

          # Resource limits
          MemoryMax = jobConfig.resources.memory;
          MemoryLow = jobConfig.resources.memoryReservation;
          CPUQuota = "${toString (builtins.floor (builtins.fromJSON jobConfig.resources.cpus * 100))}%";

          # I/O scheduling
          IOSchedulingClass = if cfg.performance.ioScheduling.enable then cfg.performance.ioScheduling.ioClass else null;
          IOSchedulingPriority = if cfg.performance.ioScheduling.enable then cfg.performance.ioScheduling.priority else null;

          # Environment
          Environment = envVars;
          EnvironmentFile = lib.mkIf (repository.environmentFile != null) repository.environmentFile;

          # Paths that need to be accessible
          ReadWritePaths = [ cfg.performance.cacheDir "/var/lib/node_exporter/textfile_collector" "/var/log/backup" ];
          ReadOnlyPaths = jobConfig.paths ++ (lib.optionals jobConfig.useSnapshots snapshotPaths);
        };

        script = ''
          set -euo pipefail

          # Metrics collection
          METRICS_FILE="/var/lib/node_exporter/textfile_collector/restic_backup_${jobName}.prom"
          START_TIME=$(date +%s)

          # Cleanup function for metrics
          cleanup() {
            local exit_code=$?
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            # Write metrics
            {
              echo "# HELP restic_backup_status Backup job status (1=success, 0=failure)"
              echo "# TYPE restic_backup_status gauge"
              echo "restic_backup_status{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

              echo "# HELP restic_backup_duration_seconds Backup job duration in seconds"
              echo "# TYPE restic_backup_duration_seconds gauge"
              echo "restic_backup_duration_seconds{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $duration"

              echo "# HELP restic_backup_last_success_timestamp Last successful backup timestamp"
              echo "# TYPE restic_backup_last_success_timestamp gauge"
              if [[ $exit_code -eq 0 ]]; then
                echo "restic_backup_last_success_timestamp{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $end_time"
              fi
            } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
          }
          trap cleanup EXIT

          echo "Starting backup for ${jobName}..."

          # Pre-backup script
          ${jobConfig.preBackupScript}

          # Initialize repository if needed
          if ! ${pkgs.restic}/bin/restic snapshots >/dev/null 2>&1; then
            echo "Initializing repository..."
            ${pkgs.restic}/bin/restic init
          fi

          # Perform backup
          ${pkgs.restic}/bin/restic backup \
            ${pathArgs} \
            ${excludeArgs} \
            ${tagArgs} \
            --verbose \
            --read-concurrency ${toString cfg.globalSettings.readConcurrency} \
            --compression ${cfg.globalSettings.compression}

          # Post-backup script
          ${jobConfig.postBackupScript}

          # Prune old snapshots
          ${pkgs.restic}/bin/restic forget \
            --tag ${lib.head jobConfig.tags} \
            --keep-daily ${toString cfg.globalSettings.retention.daily} \
            --keep-weekly ${toString cfg.globalSettings.retention.weekly} \
            --keep-monthly ${toString cfg.globalSettings.retention.monthly} \
            --keep-yearly ${toString cfg.globalSettings.retention.yearly} \
            --prune

          echo "Backup completed successfully for ${jobName}"
        '';

        # Success/failure handling
        onSuccess = [ "backup-success-notification@${jobName}.service" ];
        onFailure = [ "backup-failure-notification@${jobName}.service" ];
      };
    };

in {
  options.modules.services.backup.restic = {
    enable = lib.mkEnableOption "Restic backup integration";

    jobs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable this backup job";
          };

          repository = lib.mkOption {
            type = lib.types.str;
            description = "Repository name to use for this job";
          };

          paths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Paths to backup";
          };

          tags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Tags to apply to snapshots";
          };

          excludePatterns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Patterns to exclude from backup";
          };

          preBackupScript = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Script to run before backup";
          };

          postBackupScript = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Script to run after backup";
          };

          frequency = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            description = "Backup frequency";
          };

          resources = lib.mkOption {
            type = lib.types.submodule {
              options = {
                memory = lib.mkOption {
                  type = lib.types.str;
                  default = "512M";
                  description = "Memory limit";
                };
                memoryReservation = lib.mkOption {
                  type = lib.types.str;
                  default = "256M";
                  description = "Memory reservation";
                };
                cpus = lib.mkOption {
                  type = lib.types.str;
                  default = "1.0";
                  description = "CPU limit";
                };
              };
            };
            default = {};
            description = "Resource limits for backup job";
          };

          useSnapshots = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Use ZFS snapshots for consistent backups";
          };

          zfsDataset = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "ZFS dataset for snapshot-based backups";
          };
        };
      });
      default = {};
      description = "Restic backup jobs configuration";
    };
  };

  config = lib.mkIf (cfg.enable && resticCfg.enable) {
    # Create backup target for grouping
    systemd.targets.backup = {
      description = "Backup services target";
      wantedBy = [ "multi-user.target" ];
    };

    # Create systemd services for all backup jobs and notification templates
    systemd.services = lib.mkMerge [
      # Backup job services
      (lib.mkMerge (lib.mapAttrsToList mkBackupService
        (lib.filterAttrs (name: job: job.enable) allJobs)))

      # Notification service templates
      {
      "backup-success-notification@" = {
        description = "Backup success notification for %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "backup-success" ''
            echo "Backup succeeded for $1" | ${pkgs.systemd}/bin/systemd-cat -t backup-notify
          ''} %i";
        };
      };

      "backup-failure-notification@" = {
        description = "Backup failure notification for %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "backup-failure" ''
            echo "Backup failed for $1" | ${pkgs.systemd}/bin/systemd-cat -t backup-notify -p err
          ''} %i";
        };
      };
      }
      ];

    # Create timers for backup jobs
    systemd.timers = lib.mkMerge (lib.mapAttrsToList (jobName: jobConfig: {
      "restic-backup-${jobName}" = {
        description = "Timer for ${jobName} backup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = jobConfig.frequency;
          Persistent = true;
          RandomizedDelaySec = "30m";  # Spread backup load
        };
      };
    }) (lib.filterAttrs (name: job: job.enable) allJobs));
  };
}
