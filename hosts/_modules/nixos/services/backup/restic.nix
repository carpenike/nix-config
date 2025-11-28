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
  resticCfg = cfg.restic or { };

  # Use centralized job list from default.nix (includes both discovered and manual jobs)
  allJobs = cfg._internal.allJobs;

  # Create systemd service for each backup job
  mkBackupService = jobName: jobConfig:
    let
      repository = cfg.repositories.${jobConfig.repository} or (throw "Repository '${jobConfig.repository}' not found for backup job '${jobName}'. Available repositories: ${toString (lib.attrNames cfg.repositories)}");

      # Build snapshot paths if ZFS snapshots are enabled
      snapshotPaths =
        if jobConfig.useSnapshots && jobConfig.zfsDataset != null
        then [
          # Use the temporary clone mountpoint instead of .zfs/snapshot path
          # This avoids Restic segfaults when traversing ZFS virtual directories
          "/var/lib/backup-snapshots/${jobName}"
        ]
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

    in
    {
      "restic-backup-${jobName}" = {
        description = "Restic backup for ${jobName}";
        wants = [ "backup.target" ];
        requires = [ "network-online.target" "restic-init-${jobConfig.repository}.service" ];
        after = [ "network-online.target" "restic-init-${jobConfig.repository}.service" ] ++ lib.optionals jobConfig.useSnapshots [
          "zfs-snapshot-${jobName}.service"
        ];
        # Use BindsTo for snapshot services to create atomic lifecycle binding
        # When backup completes, systemd automatically stops the snapshot service
        bindsTo = lib.optionals jobConfig.useSnapshots [
          "zfs-snapshot-${jobName}.service"
        ];
        # Prevent concurrent execution with Syncoid replication (heavy I/O + prevents replicating ephemeral backup snapshots)
        conflicts = [ "syncoid.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = "restic-backup";
          Group = "restic-backup";

          # Restic exit codes: 0=success, 3=warning (some files couldn't be read but backup succeeded)
          # We treat warnings as success since the backup itself succeeded
          SuccessExitStatus = [ 3 ];

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
          ReadWritePaths = [
            cfg.performance.cacheDir
            "/var/lib/node_exporter/textfile_collector"
            "/var/log/backup"
          ] ++ lib.optional (repository.type == "local") repository.url;
          # When using snapshots, only grant access to snapshot paths (not original paths)
          ReadOnlyPaths = if jobConfig.useSnapshots then snapshotPaths else jobConfig.paths;
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
            local duration=$((end_time - START_TIME))

            # Common labels for all metrics
            local labels="backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",repository_name=\"${repository.repositoryName}\",repository_location=\"${repository.repositoryLocation}\",hostname=\"${config.networking.hostName}\""

            # Collect snapshot stats on success
            local files_total=0
            local size_bytes=0
            local snapshots_total=0
            local repo_healthy=0

            if [[ $exit_code -eq 0 ]]; then
              # Get latest snapshot stats for THIS job's tags - if this works, repo is healthy
              local latest_snapshot
              if latest_snapshot=$(${pkgs.restic}/bin/restic snapshots ${tagArgs} --latest 1 --json 2>/dev/null); then
                repo_healthy=1
                # Extract file count and size from the latest snapshot
                local stats
                if stats=$(echo "$latest_snapshot" | ${pkgs.jq}/bin/jq -r '.[0] | "\(.summary.files_new // 0) \(.summary.data_added // 0)"' 2>/dev/null); then
                  files_total=$(echo "$stats" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
                  size_bytes=$(echo "$stats" | ${pkgs.coreutils}/bin/cut -d' ' -f2)
                fi
                # Count total snapshots for this job's tags
                snapshots_total=$(${pkgs.restic}/bin/restic snapshots ${tagArgs} --json 2>/dev/null | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || echo 0)
              fi
            fi

            # Write metrics
            {
              echo "# HELP restic_backup_status Backup job status (1=success, 0=failure)"
              echo "# TYPE restic_backup_status gauge"
              echo "restic_backup_status{$labels} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

              echo "# HELP restic_backup_duration_seconds Backup job duration in seconds"
              echo "# TYPE restic_backup_duration_seconds gauge"
              echo "restic_backup_duration_seconds{$labels} $duration"

              echo "# HELP restic_backup_last_success_timestamp Last successful backup timestamp"
              echo "# TYPE restic_backup_last_success_timestamp gauge"
              if [[ $exit_code -eq 0 ]]; then
                echo "restic_backup_last_success_timestamp{$labels} $end_time"
              fi

              echo "# HELP restic_backup_files_total Number of new files in the latest backup snapshot"
              echo "# TYPE restic_backup_files_total gauge"
              echo "restic_backup_files_total{$labels} $files_total"

              echo "# HELP restic_backup_size_bytes Size of data added in the latest backup snapshot"
              echo "# TYPE restic_backup_size_bytes gauge"
              echo "restic_backup_size_bytes{$labels} $size_bytes"

              echo "# HELP restic_backup_snapshots_total Total snapshots for this backup job"
              echo "# TYPE restic_backup_snapshots_total gauge"
              echo "restic_backup_snapshots_total{$labels} $snapshots_total"

              echo "# HELP restic_backup_repo_healthy Repository is accessible and readable (1=healthy, 0=unhealthy)"
              echo "# TYPE restic_backup_repo_healthy gauge"
              echo "restic_backup_repo_healthy{$labels} $repo_healthy"
            } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
          }
          trap cleanup EXIT

          echo "Starting backup for ${jobName}..."

          # Pre-backup script
          ${jobConfig.preBackupScript}

          # Repository initialization is handled by dedicated restic-init service
          # All backup jobs depend on restic-init-${jobConfig.repository}.service

          # Perform backup
          # Exit code 3 = some files couldn't be read but snapshot was created
          # We treat this as success since a snapshot exists
          restic_exit=0
          ${pkgs.restic}/bin/restic backup \
            ${pathArgs} \
            ${excludeArgs} \
            ${tagArgs} \
            --verbose \
            --read-concurrency ${toString cfg.globalSettings.readConcurrency} \
            --compression ${cfg.globalSettings.compression} || restic_exit=$?

          # Exit code 3 = partial success (snapshot created, some files unreadable)
          # This is common with permission issues on temp files, plugin dirs, etc.
          if [[ $restic_exit -eq 3 ]]; then
            echo "Warning: Backup completed with some unreadable files (exit code 3)"
          elif [[ $restic_exit -ne 0 ]]; then
            echo "Backup failed with exit code $restic_exit"
            exit $restic_exit
          fi

          # Post-backup script
          ${jobConfig.postBackupScript}

          echo "Backup completed successfully for ${jobName}"
        '';

        # Success/failure handling
        onSuccess = [ "backup-success-notification@${jobName}.service" ];
        onFailure = [ "backup-failure-notification@${jobName}.service" ];
      };
    };

in
{
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
            default = [ ];
            description = "Tags to apply to snapshots";
          };

          excludePatterns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
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
            default = { };
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
      default = { };
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

      # Prune services (one per repository)
      (lib.mkMerge (lib.mapAttrsToList
        (repoName: repoConfig: lib.mkIf (repoConfig.pruneSchedule != "") {
          "restic-prune-${repoName}" = {
            description = "Prune Restic repository ${repoName}";
            requires = [ "network-online.target" "restic-init-${repoName}.service" ];
            after = [ "network-online.target" "restic-init-${repoName}.service" ];

            serviceConfig = {
              Type = "oneshot";
              User = "restic-backup";
              Group = "restic-backup";

              # Security
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;

              # Environment
              Environment = [
                "RESTIC_REPOSITORY=${repoConfig.url}"
                "RESTIC_PASSWORD_FILE=${repoConfig.passwordFile}"
                "RESTIC_CACHE_DIR=${cfg.performance.cacheDir}"
              ];
              EnvironmentFile = lib.mkIf (repoConfig.environmentFile != null) repoConfig.environmentFile;

              # Resource limits (pruning can be intensive)
              MemoryMax = "2G";
              CPUQuota = "200%";
              IOSchedulingClass = "idle";
              IOSchedulingPriority = 7;

              # Paths
              ReadWritePaths = [
                cfg.performance.cacheDir
                "/var/lib/node_exporter/textfile_collector"
                "/var/log/backup"
              ] ++ lib.optional (repoConfig.type == "local") repoConfig.url;
            };

            script = ''
              set -euo pipefail

              METRICS_FILE="/var/lib/node_exporter/textfile_collector/restic_prune_${repoName}.prom"
              START_TIME=$(date +%s)

              cleanup() {
                local exit_code=$?
                local end_time=$(date +%s)
                local duration=$((end_time - START_TIME))

                {
                  echo "# HELP restic_prune_status Prune job status (1=success, 0=failure)"
                  echo "# TYPE restic_prune_status gauge"
                  echo "restic_prune_status{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

                  echo "# HELP restic_prune_duration_seconds Prune job duration in seconds"
                  echo "# TYPE restic_prune_duration_seconds gauge"
                  echo "restic_prune_duration_seconds{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $duration"

                  echo "# HELP restic_prune_last_success_timestamp Last successful prune timestamp"
                  echo "# TYPE restic_prune_last_success_timestamp gauge"
                  if [[ $exit_code -eq 0 ]]; then
                    echo "restic_prune_last_success_timestamp{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $end_time"
                  fi
                } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
              }
              trap cleanup EXIT

              echo "Starting prune for repository ${repoName}..."

              ${pkgs.restic}/bin/restic forget \
                --keep-daily ${toString cfg.globalSettings.retention.daily} \
                --keep-weekly ${toString cfg.globalSettings.retention.weekly} \
                --keep-monthly ${toString cfg.globalSettings.retention.monthly} \
                --keep-yearly ${toString cfg.globalSettings.retention.yearly} \
                --prune

              echo "Prune completed for ${repoName}."
            '';
          };
        })
        cfg.repositories))

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

    # Create timers for backup and prune jobs
    systemd.timers = lib.mkMerge [
      # Backup timers
      (lib.mkMerge (lib.mapAttrsToList
        (jobName: jobConfig: {
          "restic-backup-${jobName}" = {
            description = "Timer for ${jobName} backup";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = jobConfig.frequency;
              Persistent = true;
              RandomizedDelaySec = "30m"; # Spread backup load
            };
          };
        })
        (lib.filterAttrs (name: job: job.enable) allJobs)))

      # Prune timers
      (lib.mkMerge (lib.mapAttrsToList
        (repoName: repoConfig: lib.mkIf (repoConfig.pruneSchedule != "") {
          "restic-prune-${repoName}" = {
            description = "Timer for ${repoName} repository prune";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = repoConfig.pruneSchedule;
              Persistent = true;
              RandomizedDelaySec = "15m"; # Good practice to avoid thundering herd
            };
          };
        })
        cfg.repositories))
    ];
  };
}
