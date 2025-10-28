# Comprehensive Backup System with ZFS Snapshot Integration
#
# This module provides a unified backup solution that coordinates:
#   - Restic encrypted backups to S3-compatible storage
#   - ZFS snapshot management via Sanoid (when enabled)
#   - Pre/post backup hooks with ZFS hold/release coordination
#   - Health monitoring and alerting via Prometheus
#   - Notification dispatch for backup events
#
# ZFS SNAPSHOT COORDINATION:
#   To prevent race conditions between Restic backups and Sanoid snapshot pruning,
#   this module implements a ZFS "hold" mechanism:
#   1. Before backup: Places holds on latest ZFS snapshots
#   2. During backup: Snapshots are protected from pruning
#   3. After backup: Releases holds to allow normal snapshot lifecycle
#
#   This ensures Restic never encounters missing snapshots mid-backup.
#
# INTEGRATION NOTES:
#   - Requires modules.backup.sanoid.enable for ZFS snapshot integration
#   - Uses notification system (modules.notifications) for event dispatch
#   - Exports metrics to Prometheus textfile collector
#   - Supports multiple backup repositories per job
#   - Environment files validated before use for security
#
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{

  options.modules.backup = {
    enable = mkEnableOption "comprehensive backup system";

    zfs = {
      enable = mkEnableOption "ZFS snapshot integration";

      pool = mkOption {
        type = types.str;
        default = "rpool";
        description = "ZFS pool to snapshot (legacy, use pools instead)";
      };

      datasets = mkOption {
        type = types.listOf types.str;
        default = [""];
        description = "Datasets to snapshot (legacy, use pools instead)";
      };

      pools = mkOption {
        type = types.listOf (types.submodule {
          options = {
            pool = mkOption {
              type = types.str;
              description = "ZFS pool name";
            };
            datasets = mkOption {
              type = types.listOf types.str;
              default = [""];
              description = "Datasets to snapshot (empty string for root dataset)";
            };
          };
        });
        default = [];
        description = ''
          List of ZFS pools and datasets to snapshot.
          This is the preferred option for multi-pool configurations.
          If not specified, will use legacy pool/datasets options for backward compatibility.
        '';
      };

      retention = mkOption {
        type = types.submodule {
          options = {
            daily = mkOption {
              type = types.int;
              default = 7;
              description = "Number of daily snapshots to keep";
            };
            weekly = mkOption {
              type = types.int;
              default = 4;
              description = "Number of weekly snapshots to keep";
            };
            monthly = mkOption {
              type = types.int;
              default = 3;
              description = "Number of monthly snapshots to keep";
            };
          };
        };
        default = {};
        description = "Snapshot retention policy";
      };
    };

    restic = {
      enable = mkEnableOption "Restic backup integration";

      globalSettings = {
        compression = mkOption {
          type = types.enum ["auto" "off" "max"];
          default = "auto";
          description = "Global compression setting for all backup jobs";
        };

        readConcurrency = mkOption {
          type = types.int;
          default = 2;
          description = "Number of concurrent read operations";
        };

        retention = mkOption {
          type = types.submodule {
            options = {
              daily = mkOption {
                type = types.int;
                default = 14;
                description = ''
                  Number of daily backups to keep.

                  RETENTION STRATEGY:
                  The default 14-8-6-2 policy provides approximately 3 months of coverage:
                  - Daily (14): Two weeks of granular recovery points
                  - Weekly (8): Two months of weekly snapshots
                  - Monthly (6): Six months of monthly archives
                  - Yearly (2): Two years for compliance/audit

                  This balances storage costs with recovery flexibility. Adjust based on:
                  - RPO (Recovery Point Objective) requirements
                  - Storage capacity and costs
                  - Compliance requirements (e.g., GDPR, SOX)
                  - Data change rate and importance
                '';
              };
              weekly = mkOption {
                type = types.int;
                default = 8;
                description = "Number of weekly backups to keep";
              };
              monthly = mkOption {
                type = types.int;
                default = 6;
                description = "Number of monthly backups to keep";
              };
              yearly = mkOption {
                type = types.int;
                default = 2;
                description = "Number of yearly backups to keep";
              };
            };
          };
          default = {};
          description = "Global retention policy for Restic backups";
        };
      };

      repositories = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Repository URL (local path or cloud endpoint)";
              example = "b2:bucket-name:/path or /mnt/nas/backups";
            };

            passwordFile = mkOption {
              type = types.path;
              description = ''
                Path to file containing repository password.
                WARNING: If this is a plain file, it will be world-readable in the Nix store.
                Use a path from a secrets tool like sops, e.g. `sops.secrets.restic-password.path`.
              '';
            };

            environmentFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to environment file with cloud credentials";
            };

            primary = mkOption {
              type = types.bool;
              default = false;
              description = "Whether this is the primary repository";
            };
          };
        });
        default = {};
        description = "Restic repositories configuration";
      };

      jobs = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            enable = mkEnableOption "this backup job";

            paths = mkOption {
              type = types.listOf types.str;
              description = "Paths to backup (will be prefixed with /mnt/backup-snapshot if ZFS enabled)";
            };

            excludePatterns = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Patterns to exclude from backup";
            };

            repository = mkOption {
              type = types.str;
              description = "Repository name to use for this job";
            };

            tags = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Additional tags for this backup job";
            };

            preBackupScript = mkOption {
              type = types.lines;
              default = "";
              description = "Script to run before backup";
            };

            postBackupScript = mkOption {
              type = types.lines;
              default = "";
              description = "Script to run after backup";
            };

            resources = mkOption {
              type = types.submodule {
                options = {
                  memory = mkOption {
                    type = types.str;
                    default = "256M";
                    description = "Memory limit for backup process";
                  };
                  memoryReservation = mkOption {
                    type = types.str;
                    default = "128M";
                    description = "Memory reservation for backup process";
                  };
                  cpus = mkOption {
                    type = types.str;
                    default = "0.5";
                    description = "CPU limit for backup process";
                  };
                };
              };
              default = {};
              description = "Resource limits for this backup job";
            };

          };
        });
        default = {};
        description = "Backup job configurations";
      };
    };

    monitoring = {
      enable = mkEnableOption "backup monitoring and notifications";

      healthchecks = {
        enable = mkEnableOption "Healthchecks.io monitoring";

        baseUrl = mkOption {
          type = types.str;
          default = "https://hc-ping.com";
          description = "Healthchecks.io base URL";
        };

        uuidFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to file containing Healthchecks.io UUID";
        };
      };



      onFailure = {
        enable = mkEnableOption "immediate failure notifications via systemd OnFailure";

        notificationScript = mkOption {
          type = types.lines;
          default = "";
          description = "Custom script to run when backup jobs fail. Available variables: JOB_NAME, REPO_URL, HOSTNAME";
        };
      };

      prometheus = {
        enable = mkEnableOption "Prometheus metrics export via Node Exporter textfile collector";

        metricsDir = mkOption {
          type = types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for Node Exporter textfile collector metrics";
        };
        collectRepoCounters = mkOption {
          type = types.bool;
          default = true;
          description = "Emit repository-wide counters (restic_snapshots_total) during verification runs.";
        };
        collectLocks = mkOption {
          type = types.bool;
          default = true;
          description = "Emit repository locks count (restic_locks_total) during verification runs.";
        };
      };

      logDir = mkOption {
        type = types.path;
        default = "/var/log/backup";
        description = "Directory for structured backup logs";
      };

      errorAnalysis = {
        enable = mkEnableOption "intelligent error categorization and analysis";

        categoryRules = mkOption {
          type = types.listOf (types.submodule {
            options = {
              pattern = mkOption {
                type = types.str;
                description = "Regex pattern to match error messages";
              };
              category = mkOption {
                type = types.str;
                description = "Error category (network, storage, permission, authentication, corruption, resource)";
              };
              severity = mkOption {
                type = types.enum ["critical" "high" "medium" "low"];
                default = "medium";
                description = "Severity level for this error type";
              };
              actionable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether this error type typically requires human intervention";
              };
              retryable = mkOption {
                type = types.bool;
                default = false;
                description = "Whether this error type might succeed on retry";
              };
            };
          });
          default = [
            {
              pattern = "(connection refused|network unreachable|timeout|dns resolution failed)";
              category = "network";
              severity = "high";
              actionable = true;
              retryable = true;
            }
            {
              pattern = "(no space left|disk full|quota exceeded|storage full)";
              category = "storage";
              severity = "critical";
              actionable = true;
              retryable = false;
            }
            {
              pattern = "(permission denied|access denied|authentication failed|invalid credentials)";
              category = "permission";
              severity = "high";
              actionable = true;
              retryable = false;
            }
            {
              pattern = "(repository not found|invalid repository|corrupted data|checksum mismatch)";
              category = "corruption";
              severity = "critical";
              actionable = true;
              retryable = false;
            }
            {
              pattern = "(out of memory|cannot allocate|resource temporarily unavailable)";
              category = "resource";
              severity = "medium";
              actionable = true;
              retryable = true;
            }
          ];
          description = "Rules for categorizing backup errors";
        };
      };
    };

    verification = {
      enable = mkEnableOption "automated backup verification and integrity checking";

      schedule = mkOption {
        type = types.str;
        default = "weekly";
        description = "Schedule for repository integrity checks (daily/weekly/monthly)";
      };

      checkData = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to verify actual data content (--read-data). CPU intensive but thorough";
      };

      checkDataSubset = mkOption {
        type = types.str;
        default = "5%";
        description = "Percentage of data to verify when checkData is false (e.g., '5%', '1G')";
      };
    };

    restoreTesting = {
      enable = mkEnableOption "automated restore testing and validation";

      schedule = mkOption {
        type = types.str;
        default = "monthly";
        description = "Schedule for restore tests (daily/weekly/monthly)";
      };

      testDir = mkOption {
        type = types.path;
        default = "/tmp/backup-restore-test";
        description = "Directory for restore testing";
      };

      sampleFiles = mkOption {
        type = types.int;
        default = 10;
        description = "Number of random files to test restore for";
      };

      retainTestData = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to retain test restore data after validation";
      };
    };

    validation = {
      enable = mkEnableOption "configuration validation and pre-flight checks";

      preFlightChecks = {
        enable = mkEnableOption "pre-backup validation checks";

        minFreeSpace = mkOption {
          type = types.str;
          default = "10G";
          description = "Minimum free space required for backup operations";
        };

        networkTimeout = mkOption {
          type = types.int;
          default = 30;
          description = "Network connectivity timeout in seconds";
        };
      };

      repositoryHealth = {
        enable = mkEnableOption "repository health monitoring";

        maxAge = mkOption {
          type = types.str;
          default = "48h";
          description = "Maximum age of latest backup before alerting";
        };

        minBackups = mkOption {
          type = types.int;
          default = 3;
          description = "Minimum number of backups to maintain";
        };
      };
    };

    performance = {
      cacheDir = mkOption {
        type = types.path;
        default = "/var/cache/restic";
        description = "Restic cache directory (should be on fast storage)";
      };

      cacheSizeLimit = mkOption {
        type = types.str;
        default = "1G";
        description = "Maximum cache size";
      };

      ioScheduling = {
        enable = mkEnableOption "I/O scheduling optimization for backup processes";

        ioClass = mkOption {
          type = types.enum ["idle" "best-effort" "realtime"];
          default = "idle";
          description = "I/O scheduling class for backup processes";
        };

        priority = mkOption {
          type = types.int;
          default = 7;
          description = "I/O priority level (0-7, higher is lower priority)";
        };
      };
    };

    security = {
      enable = mkEnableOption "enhanced security hardening for backup operations";

      restrictNetwork = mkOption {
        type = types.bool;
        default = true;
        description = "Restrict network access to only backup repositories";
      };

      readOnlyRootfs = mkOption {
        type = types.bool;
        default = true;
        description = "Use read-only root filesystem for backup processes";
      };

      auditLogging = mkOption {
        type = types.bool;
        default = true;
        description = "Enable detailed audit logging for backup operations";
      };
    };

    documentation = {
      enable = mkEnableOption "automated documentation and runbook generation";

      outputDir = mkOption {
        type = types.path;
        default = "/var/lib/backup-docs";
        description = "Directory for generated documentation";
      };

      includeMetrics = mkOption {
        type = types.bool;
        default = true;
        description = "Include performance metrics in documentation";
      };
    };

    schedule = mkOption {
      type = types.str;
      default = "02:00";
      description = "Time to run backups (24-hour format)";
    };
  };

  config = let
    cfg = config.modules.backup;
    notificationsCfg = config.modules.notifications;

    # Check if centralized notifications are available
    hasCentralizedNotifications = notificationsCfg.enable or false;

    # Detect if using legacy default configuration (likely misconfigured)
    # Note: zfsPools variable removed during Sanoid migration (2025-10-14)
    # ZFS snapshot management is now handled by Sanoid, not this module
    zfsLegacyFallback = (cfg.zfs.pools == [])
                     && (cfg.zfs.pool == "rpool")
                     && (cfg.zfs.datasets == [""]);
  in mkIf cfg.enable {

    # Operational safety warnings
    warnings =
      (optional (!cfg.zfs.enable && (cfg.restic.jobs == {}))
        "modules.backup is enabled but no backup jobs are configured (both ZFS snapshots and Restic jobs are disabled)")
      ++ (optional (cfg.zfs.enable && zfsLegacyFallback)
        "modules.backup.zfs is enabled and using legacy defaults (pool=rpool, root dataset). If this is intended, ignore this warning. Otherwise configure modules.backup.zfs.pools for explicit datasets.")
      ++ (optional (cfg.restic.enable && cfg.restic.jobs == {})
        "modules.backup.restic is enabled but no backup jobs are configured");

    # Create restic-backup system user and group
    users.users.restic-backup = {
      isSystemUser = true;
      group = "restic-backup";
      description = "Restic backup service user";
      # Add to node-exporter group for Prometheus metrics export
      extraGroups = mkIf cfg.monitoring.prometheus.enable [ "node-exporter" ];
    };
    users.groups.restic-backup = {};

    # Register notification templates if notification system is enabled
    modules.notifications.templates = mkIf hasCentralizedNotifications {
      backup-success = {
        enable = mkDefault true;
        priority = mkDefault "low";  # Low priority to reduce noise
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="green">✓ Backup Success: ''${jobName}</font></b>'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Repository:</b> <code>''${repository}</code>

          <b>Duration:</b>   ''${duration}
          <b>Files Added:</b> ''${filesCount}
          <b>Data Added:</b>  ''${dataSize}

          <a href="https://grafana.holthome.net/d/backups?var-job=''${jobName}">View Trends →</a>
        '';
      };

      backup-failure = {
        enable = mkDefault true;
        priority = mkDefault "high";  # High priority for failures
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="red">✗ Backup Failed: ''${jobName}</font></b>'';
        body = mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Repository:</b> <code>''${repository}</code>

          <b>Error:</b>
          <font color="#ff5733"><code>''${errorMessage}</code></font>

          <b>Quick Actions:</b>
          1. <a href="https://grafana.holthome.net/d/backups">View Dashboard</a>
          2. Check logs:
             <code>ssh ''${hostname} 'journalctl -u restic-backups-''${jobName} -n 100'</code>
          3. Test repository:
             <code>restic -r ''${repository} check --read-data-subset=5%</code>
        '';
      };

      verification-failure = {
        enable = mkDefault true;
        priority = mkDefault "high";
        backend = mkDefault "pushover";
        title = mkDefault ''<b><font color="red">✗ Backup Verification Failed</font></b>'';
        body = mkDefault ''
          <b>Repository:</b> <code>''${repositoryName}</code>

          <b>Issue:</b> Repository integrity check detected problems

          <b>Actions Required:</b>
          1. <a href="https://grafana.holthome.net/d/backups?var-repo=''${repositoryName}">View History</a>
          2. Check details:
             <code>restic -r ''${repository} check --read-data</code>
          3. Review backup docs:
             <code>cat /var/lib/backup/docs/troubleshooting.md</code>
        '';
      };
    };

    # Ensure required packages are available
    environment.systemPackages = with pkgs; [
      restic
      zfs
      curl
    ];

    # ZFS snapshots are managed by Sanoid (see hosts/_modules/nixos/storage/sanoid.nix)
    # Restic backups use .zfs/snapshot path resolution (see backupPrepareCommand below)
    # Legacy zfs-snapshot service removed 2025-10-14 during Sanoid migration

    systemd.services = mkMerge [
      # Apply I/O and CPU scheduling to restic backup services
      # Note: restic doesn't honor RESTIC_IONICE_* environment variables, so we override
      # the systemd service config directly
      (mkMerge (mapAttrsToList (jobName: jobConfig:
        mkIf (jobConfig.enable && cfg.performance.ioScheduling.enable) {
          "restic-backups-${jobName}" = {
            serviceConfig = {
              IOSchedulingClass = cfg.performance.ioScheduling.ioClass;
              IOSchedulingPriority = cfg.performance.ioScheduling.priority;
              CPUSchedulingPolicy = "idle";

              # Apply per-job resource limits from configuration
              # Normalize memory units to uppercase (systemd expects e.g. '128M', '1G')
              MemoryMax = lib.strings.toUpper (jobConfig.resources.memory);
              MemoryHigh = lib.strings.toUpper (jobConfig.resources.memoryReservation);
              # Convert CPUs string (e.g., "0.5") to percentage for CPUQuota
              # Use builtins.fromJSON to parse string as number (Nix doesn't have toFloat)
              CPUQuota = "${toString (builtins.floor ((builtins.fromJSON jobConfig.resources.cpus) * 100))}%";

              # Serialize heavy I/O: avoid contention with Syncoid replication jobs
              # Note: Conflicts is a [Unit] directive; set it in unitConfig below

              # Automatic retry on transient failures (network issues, temporary I/O errors)
              # Restart=on-failure: Retry if the service exits with non-zero status
              # RestartSec=5m: Wait 5 minutes before retry to avoid hammering failed resources
              # Restart on transient failures with exponential backoff
              Restart = "on-failure";
              RestartSec = "5m";

              # Harden shutdown: kill all processes in cgroup after 2 minutes
              TimeoutStopSec = "2m";
              KillMode = "control-group";
            };
            unitConfig = {
              # StartLimitBurst=3: Allow up to 3 restart attempts
              # StartLimitIntervalSec=24h: Reset the attempt counter after 24 hours
              StartLimitBurst = 3;
              StartLimitIntervalSec = "24h";
              # Group restic backup services under a common target for coordination
              PartOf = [ "restic-backups.target" ];
              # Ensure backups run after Sanoid snapshot creation
              After = [ "sanoid.service" ];
            };
            # Prevent concurrent execution with Syncoid replication jobs (heavy I/O serialization)
            # Use the dedicated NixOS option to place this in the [Unit] section
            conflicts = [ "syncoid.target" ];
          };
        }
      ) cfg.restic.jobs))

      # Phase 3 services: Repository verification services
      (mkMerge (mapAttrsToList (repoName: repoConfig:
        mkIf cfg.verification.enable {
          "restic-check-${repoName}" = {
            description = "Restic repository integrity check for ${repoName}";
            path = with pkgs; [ restic curl jq ];
            script = ''
              set -euo pipefail

              echo "Starting repository integrity check for ${repoName}..."
              START_TIME=$(date +%s)

              ${optionalString ((repoConfig.environmentFile or null) != null) ''
                # Source environment file for restic credentials
                set -a
                . "${repoConfig.environmentFile}"
                set +a
              ''}

              # Run repository check
              CHECK_ARGS=(
                -r "${repoConfig.url}"
                --password-file "${repoConfig.passwordFile}"
                check
                ${optionalString cfg.verification.checkData "--read-data"}
                ${optionalString (!cfg.verification.checkData) "--read-data-subset=${cfg.verification.checkDataSubset}"}
              )

              if restic "''${CHECK_ARGS[@]}"; then
                STATUS="success"
                echo "Repository check completed successfully for ${repoName}"
              else
                STATUS="failure"
                echo "Repository check failed for ${repoName}"
              fi

              END_TIME=$(date +%s)
              DURATION=$((END_TIME - START_TIME))

              ${optionalString cfg.monitoring.enable ''
                # Log verification result
                TIMESTAMP=$(date --iso-8601=seconds)
                LOG_FILE="${cfg.monitoring.logDir}/backup-verification.jsonl"

                jq -n \
                  --arg timestamp "$TIMESTAMP" \
                  --arg repository "${repoName}" \
                  --arg repo_url "${repoConfig.url}" \
                  --arg event "verification_complete" \
                  --arg status "$STATUS" \
                  --arg duration "$DURATION" \
                  --arg hostname "${config.networking.hostName}" \
                  '{
                    timestamp: $timestamp,
                    event: $event,
                    repository: $repository,
                    repository_url: $repo_url,
                    status: $status,
                    duration_seconds: ($duration | tonumber),
                    hostname: $hostname
                  }' >> "$LOG_FILE" || true
              ''}

              ${optionalString cfg.monitoring.prometheus.enable ''
                # Export verification metrics
                METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/restic_verification_${repoName}.prom"
                METRICS_TEMP="$METRICS_FILE.tmp"
                TIMESTAMP=$(date +%s)
                STATUS_VALUE=$([ "$STATUS" = "success" ] && echo 1 || echo 0)

                cat > "$METRICS_TEMP" <<EOF
# HELP restic_verification_duration_seconds Duration of repository verification in seconds
# TYPE restic_verification_duration_seconds gauge
restic_verification_duration_seconds{repository="${repoName}",hostname="${config.networking.hostName}"} $DURATION

# HELP restic_verification_last_run_timestamp Last verification run timestamp
# TYPE restic_verification_last_run_timestamp gauge
restic_verification_last_run_timestamp{repository="${repoName}",hostname="${config.networking.hostName}"} $TIMESTAMP

# HELP restic_verification_status Verification status (1=success, 0=failure)
# TYPE restic_verification_status gauge
restic_verification_status{repository="${repoName}",hostname="${config.networking.hostName}"} $STATUS_VALUE
EOF
                # Optional: repository-wide counters for parity (snapshots_total, locks_total)
                if [ "${toString cfg.monitoring.prometheus.collectRepoCounters}" = "true" ]; then
                  ${optionalString ((repoConfig.environmentFile or null) != null) ''
                    if [ -f "${repoConfig.environmentFile}" ]; then
                      set -a
                      . "${repoConfig.environmentFile}"
                      set +a
                    fi
                  ''}
                  SNAP_COUNT=$(${pkgs.restic}/bin/restic -r "${repoConfig.url}" --password-file "${repoConfig.passwordFile}" \
                    snapshots --json 2>/dev/null | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || echo 0)
                  echo "# HELP restic_snapshots_total Total number of snapshots in the repository" >> "$METRICS_TEMP"
                  echo "# TYPE restic_snapshots_total counter" >> "$METRICS_TEMP"
                  echo "restic_snapshots_total{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $SNAP_COUNT" >> "$METRICS_TEMP"
                  if [ "${toString cfg.monitoring.prometheus.collectLocks}" = "true" ]; then
                    # Note: locks listing may be expensive on cloud backends; best-effort only
                    LOCKS_COUNT=$(${pkgs.restic}/bin/restic -r "${repoConfig.url}" --password-file "${repoConfig.passwordFile}" \
                      list locks 2>/dev/null | ${pkgs.coreutils}/bin/wc -l | ${pkgs.coreutils}/bin/tr -d ' ' || echo 0)
                    echo "# HELP restic_locks_total Total number of locks in the repository" >> "$METRICS_TEMP"
                    echo "# TYPE restic_locks_total counter" >> "$METRICS_TEMP"
                    echo "restic_locks_total{repository=\"${repoName}\",hostname=\"${config.networking.hostName}\"} $LOCKS_COUNT" >> "$METRICS_TEMP"
                  fi
                fi
                mv "$METRICS_TEMP" "$METRICS_FILE"
              ''}

              [ "$STATUS" = "success" ]
            '';
            unitConfig = {
              # Notify on verification failures
              # Pass %n (unit name) so dispatcher can extract logs
              OnFailure = mkIf (hasCentralizedNotifications && (notificationsCfg.templates.verification-failure.enable or false))
                [ "notify@verification-failure:%n.service" ];
            };
            serviceConfig = {
              Type = "oneshot";
              User = "restic-backup";
              Group = "restic-backup";
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
              ReadWritePaths = mkMerge [
                [ cfg.performance.cacheDir ]
                (mkIf cfg.monitoring.enable [ cfg.monitoring.logDir ])
                (mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ])
              ];
            };
          };
        }
      ) cfg.restic.repositories))

      # Phase 3 services: Repository restore testing services
      (mkMerge (mapAttrsToList (repoName: repoConfig:
        mkIf cfg.restoreTesting.enable {
          "restic-restore-test-${repoName}" = {
            description = "Automated restore testing for ${repoName}";
            path = with pkgs; [ restic curl jq coreutils findutils ];
            script = ''
              set -euo pipefail

              echo "Starting restore test for repository ${repoName}..."
              START_TIME=$(date +%s)
              TEST_DIR="${cfg.restoreTesting.testDir}/${repoName}-$(date +%Y%m%d-%H%M%S)"
              mkdir -p "$TEST_DIR"

              ${optionalString ((repoConfig.environmentFile or null) != null) ''
                # Source environment file for restic credentials
                set -a
                . "${repoConfig.environmentFile}"
                set +a
              ''}

              # Get list of snapshots
              SNAPSHOTS=$(restic -r "${repoConfig.url}" \
                --password-file "${repoConfig.passwordFile}" \
                snapshots --json)

              if [ -z "$SNAPSHOTS" ] || [ "$SNAPSHOTS" = "[]" ]; then
                echo "No snapshots found in repository ${repoName}"
                exit 1
              fi

              # Get latest snapshot ID
              LATEST_SNAPSHOT=$(echo "$SNAPSHOTS" | jq -r '.[-1].id')
              echo "Testing restore from snapshot: $LATEST_SNAPSHOT"

              # List files in snapshot and select random samples
              FILES_JSON=$(restic -r "${repoConfig.url}" \
                --password-file "${repoConfig.passwordFile}" \
                ls "$LATEST_SNAPSHOT" --json)

              # Select random files for testing
              SAMPLE_FILES=$(echo "$FILES_JSON" | jq -r \
                'map(select(.type == "file")) | .[0:${toString cfg.restoreTesting.sampleFiles}] | .[].path')

              if [ -z "$SAMPLE_FILES" ]; then
                echo "No files found to test restore"
                exit 1
              fi

              # Restore sample files
              RESTORED_COUNT=0
              FAILED_COUNT=0

              while IFS= read -r file; do
                if [ -n "$file" ]; then
                  echo "Restoring file: $file"
                  if restic -r "${repoConfig.url}" \
                    --password-file "${repoConfig.passwordFile}" \
                    restore "$LATEST_SNAPSHOT" --target "$TEST_DIR" --include "$file"; then
                    RESTORED_COUNT=$((RESTORED_COUNT + 1))
                  else
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                    echo "Failed to restore: $file"
                  fi
                fi
              done <<< "$SAMPLE_FILES"

              END_TIME=$(date +%s)
              DURATION=$((END_TIME - START_TIME))

              if [ $FAILED_COUNT -eq 0 ]; then
                STATUS="success"
                echo "Restore test completed successfully. Restored $RESTORED_COUNT files"
              else
                STATUS="failure"
                echo "Restore test failed. $FAILED_COUNT failures out of $RESTORED_COUNT attempts"
              fi

              # Cleanup test data unless retained
              ${optionalString (!cfg.restoreTesting.retainTestData) ''
                echo "Cleaning up test restore data..."
                rm -rf "$TEST_DIR"
              ''}

              ${optionalString cfg.monitoring.enable ''
                # Log restore test result
                TIMESTAMP=$(date --iso-8601=seconds)
                LOG_FILE="${cfg.monitoring.logDir}/backup-restore-tests.jsonl"

                jq -n \
                  --arg timestamp "$TIMESTAMP" \
                  --arg repository "${repoName}" \
                  --arg repo_url "${repoConfig.url}" \
                  --arg event "restore_test_complete" \
                  --arg status "$STATUS" \
                  --arg duration "$DURATION" \
                  --arg restored_count "$RESTORED_COUNT" \
                  --arg failed_count "$FAILED_COUNT" \
                  --arg snapshot_id "$LATEST_SNAPSHOT" \
                  --arg hostname "${config.networking.hostName}" \
                  '{
                    timestamp: $timestamp,
                    event: $event,
                    repository: $repository,
                    repository_url: $repo_url,
                    status: $status,
                    duration_seconds: ($duration | tonumber),
                    restored_count: ($restored_count | tonumber),
                    failed_count: ($failed_count | tonumber),
                    snapshot_id: $snapshot_id,
                    hostname: $hostname
                  }' >> "$LOG_FILE" || true
              ''}

              ${optionalString cfg.monitoring.prometheus.enable ''
                # Export restore test metrics
                METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/restic_restore_test_${repoName}.prom"
                METRICS_TEMP="$METRICS_FILE.tmp"
                TIMESTAMP=$(date +%s)
                STATUS_VALUE=$([ "$STATUS" = "success" ] && echo 1 || echo 0)

                cat > "$METRICS_TEMP" <<EOF
# HELP restic_restore_test_duration_seconds Duration of restore test in seconds
# TYPE restic_restore_test_duration_seconds gauge
restic_restore_test_duration_seconds{repository="${repoName}",hostname="${config.networking.hostName}"} $DURATION

# HELP restic_restore_test_last_run_timestamp Last restore test run timestamp
# TYPE restic_restore_test_last_run_timestamp gauge
restic_restore_test_last_run_timestamp{repository="${repoName}",hostname="${config.networking.hostName}"} $TIMESTAMP

# HELP restic_restore_test_status Restore test status (1=success, 0=failure)
# TYPE restic_restore_test_status gauge
restic_restore_test_status{repository="${repoName}",hostname="${config.networking.hostName}"} $STATUS_VALUE

# HELP restic_restore_test_files_restored Number of files successfully restored
# TYPE restic_restore_test_files_restored gauge
restic_restore_test_files_restored{repository="${repoName}",hostname="${config.networking.hostName}"} $RESTORED_COUNT

# HELP restic_restore_test_files_failed Number of files that failed to restore
# TYPE restic_restore_test_files_failed gauge
restic_restore_test_files_failed{repository="${repoName}",hostname="${config.networking.hostName}"} $FAILED_COUNT
EOF
                mv "$METRICS_TEMP" "$METRICS_FILE"
              ''}

              [ "$STATUS" = "success" ]
            '';
            serviceConfig = {
              Type = "oneshot";
              User = "restic-backup";
              Group = "restic-backup";
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
              ReadWritePaths = mkMerge [
                [ cfg.performance.cacheDir cfg.restoreTesting.testDir ]
                (mkIf cfg.monitoring.enable [ cfg.monitoring.logDir ])
                (mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ])
              ];
            };
          };
        }
      ) cfg.restic.repositories))

      # Failure notification services for immediate alerting
      (mkMerge (mapAttrsToList (jobName: jobConfig:
        let
          repo = cfg.restic.repositories.${jobConfig.repository} or {};
        in
        mkIf (jobConfig.enable && cfg.monitoring.onFailure.enable) {
          "backup-failure-${jobName}" = {
            description = "Backup failure notification for ${jobName}";
            path = with pkgs; [ curl jq coreutils ];
            script = ''
              set -euo pipefail

              JOB_NAME="${jobName}"
              REPO_URL="${repo.url}"
              HOSTNAME="${config.networking.hostName}"
              TIMESTAMP=$(date --iso-8601=seconds)

              echo "Backup job ${jobName} failed on ${config.networking.hostName}"

              ${optionalString cfg.monitoring.enable ''
                # Log failure event with error message from journal
                LOG_FILE="${cfg.monitoring.logDir}/backup-failures.jsonl"

                # Extract recent error message from the failed service journal
                ERROR_MESSAGE=$(journalctl -u restic-backups-${jobName}.service -b -n 200 -o cat 2>/dev/null \
                  | grep -Ei 'error|failed|permission|denied|timeout|dns|refused|quota|space|corrupt' \
                  | tail -n 1 \
                  | sed "s/\"/'/g" \
                  | head -c 500 || echo "No error details available")

                jq -n \
                  --arg timestamp "$TIMESTAMP" \
                  --arg job "$JOB_NAME" \
                  --arg repo "$REPO_URL" \
                  --arg hostname "$HOSTNAME" \
                  --arg event "backup_failure" \
                  --arg error_message "$ERROR_MESSAGE" \
                  '{
                    timestamp: $timestamp,
                    event: $event,
                    job_name: $job,
                    repository: $repo,
                    hostname: $hostname,
                    error_message: $error_message,
                    severity: "critical"
                  }' >> "$LOG_FILE" || true
              ''}

              ${optionalString cfg.monitoring.prometheus.enable ''
                # Export failure metrics to the same file as success (avoids duplicate series)
                METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/restic_backup_${jobName}.prom"
                METRICS_TEMP="$METRICS_FILE.tmp"
                TIMESTAMP_UNIX=$(date +%s)

                cat > "$METRICS_TEMP" <<EOF
# HELP restic_backup_last_failure_timestamp Last backup failure timestamp
# TYPE restic_backup_last_failure_timestamp gauge
restic_backup_last_failure_timestamp{backup_job="${jobName}",repository="${jobConfig.repository}",hostname="${config.networking.hostName}"} $TIMESTAMP_UNIX

# HELP restic_backup_status Backup job status (1=success, 0=failure)
# TYPE restic_backup_status gauge
restic_backup_status{backup_job="${jobName}",repository="${jobConfig.repository}",hostname="${config.networking.hostName}"} 0
EOF
                mv "$METRICS_TEMP" "$METRICS_FILE"
              ''}

              # Legacy healthchecks.io support (kept for backward compatibility)
              ${optionalString cfg.monitoring.healthchecks.enable ''
                # Send failure notification to Healthchecks.io
                if [ -f "${cfg.monitoring.healthchecks.uuidFile}" ]; then
                  UUID=$(cat "${cfg.monitoring.healthchecks.uuidFile}")
                  curl -fsS -m 10 --retry 3 \
                    --data-raw "Backup job ${jobName} failed on ${config.networking.hostName}" \
                    "${cfg.monitoring.healthchecks.baseUrl}/$UUID/fail" || true
                fi
              ''}

              ${optionalString (cfg.monitoring.onFailure.notificationScript != "") cfg.monitoring.onFailure.notificationScript}

              echo "Failure notifications sent for backup job ${jobName}"
            '';
            serviceConfig = {
              Type = "oneshot";
              User = "restic-backup";
              Group = "restic-backup";
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
              ReadWritePaths = mkMerge [
                (mkIf cfg.monitoring.enable [ cfg.monitoring.logDir ])
                (mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ])
              ];
            };
          };
        }
      ) cfg.restic.jobs))

      # Error analysis service for intelligent error categorization
      (mkIf cfg.monitoring.errorAnalysis.enable {
        backup-error-analyzer = {
          description = "Intelligent backup error analysis and categorization";
          path = with pkgs; [ jq gnugrep gawk coreutils util-linux findutils ];
          script = ''
            set -euo pipefail
            set -x

            LOG_DIR="${cfg.monitoring.logDir}"
            ANALYSIS_LOG="$LOG_DIR/error-analysis.jsonl"
            STATE_FILE="/var/lib/backup/error-analyzer.state"
            LOCK_FILE="/var/lib/backup/error-analyzer.lock"
            TIMESTAMP=$(date --iso-8601=seconds)

            # Acquire lock to prevent concurrent runs
            exec 9>"$LOCK_FILE"
            if ! flock -n 9; then
              echo "Error analyzer already running, exiting"
              exit 0
            fi

            # Create state directory if it doesn't exist
            mkdir -p "$(dirname "$STATE_FILE")"
            # Ensure log directory and analysis log exist
            mkdir -p "$LOG_DIR"
            : > "$ANALYSIS_LOG"

            # Read last processed timestamp (default to 1 hour ago if state file doesn't exist)
            if [ -f "$STATE_FILE" ]; then
              LAST_PROCESSED=$(cat "$STATE_FILE")
            else
              LAST_PROCESSED=$(date --iso-8601=seconds -d '1 hour ago')
            fi

            # Convert to epoch time for reliable comparison (handles timezones)
            LAST_EPOCH=$(date -d "$LAST_PROCESSED" +%s 2>/dev/null || echo "0")

            echo "Starting backup error analysis (processing events since $LAST_PROCESSED)..."

            # Track the maximum event timestamp seen for state file update
            MAX_TS="$LAST_PROCESSED"

            # Process recent error logs from the last 24 hours
            find "$LOG_DIR" -name "*.jsonl" -mtime -1 -type f | while read -r logfile; do
              echo "Analyzing log file: $logfile"

              # Extract error events from JSON logs (including *_complete events with non-success status)
              # Only process events newer than LAST_PROCESSED to avoid duplicates (using epoch time)
              jq -Rr --argjson last_epoch "$LAST_EPOCH" '
                fromjson? | select(type == "object") |
                select(
                  (((.timestamp) | (try fromdateiso8601 catch 0)) // 0) > $last_epoch and (
                    (.event == "backup_failure") or
                    (.event == "verification_complete" and .status != "success") or
                    (.event == "restore_test_complete" and .status != "success")
                  )
                ) |
                @base64
              ' "$logfile" 2>/dev/null | while read -r encoded_line; do
                if [ -n "$encoded_line" ]; then
                  line=$(echo "$encoded_line" | base64 -d)

                  # Extract relevant fields
                  event_timestamp=$(echo "$line" | jq -r '.timestamp // empty')
                  job_name=$(echo "$line" | jq -r '.job_name // .repository // "unknown"')
                  error_message=$(echo "$line" | jq -r '.error_message // .status // "unknown"')
                  hostname=$(echo "$line" | jq -r '.hostname // "${config.networking.hostName}"')

                  if [ -n "$event_timestamp" ] && [ "$error_message" != "success" ]; then
                    # Track max timestamp for state file
                    EVENT_EPOCH=$(date -d "$event_timestamp" +%s 2>/dev/null || echo "0")
                    MAX_EPOCH=$(date -d "$MAX_TS" +%s 2>/dev/null || echo "0")
                    if [ "$EVENT_EPOCH" -gt "$MAX_EPOCH" ]; then
                      MAX_TS="$event_timestamp"
                    fi

                    # Categorize the error using configured rules
                    category="unknown"
                    severity="medium"
                    actionable=true
                    retryable=false

                    ${concatStringsSep "\n" (map (rule: ''
                      if echo "$error_message" | grep -qiE "${rule.pattern}"; then
                        category="${rule.category}"
                        severity="${rule.severity}"
                        actionable=${if rule.actionable then "true" else "false"}
                        retryable=${if rule.retryable then "true" else "false"}
                      fi
                    '') cfg.monitoring.errorAnalysis.categoryRules)}

                    # Generate analysis entry
                    jq -n \
                      --arg timestamp "$TIMESTAMP" \
                      --arg original_timestamp "$event_timestamp" \
                      --arg job_name "$job_name" \
                      --arg hostname "$hostname" \
                      --arg error_message "$error_message" \
                      --arg category "$category" \
                      --arg severity "$severity" \
                      --arg actionable "$actionable" \
                      --arg retryable "$retryable" \
                      --arg event "error_analysis" \
                      '{
                        timestamp: $timestamp,
                        event: $event,
                        analysis: {
                          original_timestamp: $original_timestamp,
                          job_name: $job_name,
                          hostname: $hostname,
                          error_message: $error_message,
                          category: $category,
                          severity: $severity,
                          actionable: ($actionable == "true"),
                          retryable: ($retryable == "true")
                        }
                      }' >> "$ANALYSIS_LOG" || true
                  fi
                fi
              done
            done

            ${optionalString cfg.monitoring.prometheus.enable ''
              # Export error analysis metrics
              METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/backup_error_analysis.prom"
              METRICS_TEMP="$METRICS_FILE.tmp"
              TIMESTAMP_UNIX=$(date +%s)

              # Calculate 24-hour cutoff timestamp
              CUTOFF_EPOCH=$(( TIMESTAMP_UNIX - 86400 ))

              # Count errors by category and severity in the last 24 hours
              cat > "$METRICS_TEMP" <<EOF
# HELP backup_errors_by_category_total Total backup errors by category in last 24 hours
# TYPE backup_errors_by_category_total gauge
EOF

              for category in network storage permission corruption resource unknown; do
                count=$(jq -Rr --argjson cutoff "$CUTOFF_EPOCH" --arg cat "$category" \
                  'fromjson? | select(type == "object") | select((((.analysis.original_timestamp) | (try fromdateiso8601 catch 0)) // 0) >= $cutoff and .analysis.category == $cat)' \
                  "$ANALYSIS_LOG" 2>/dev/null | wc -l)
                echo "backup_errors_by_category_total{category=\"$category\",hostname=\"${config.networking.hostName}\"} $count" >> "$METRICS_TEMP"
              done

              cat >> "$METRICS_TEMP" <<EOF

# HELP backup_errors_by_severity_total Total backup errors by severity in last 24 hours
# TYPE backup_errors_by_severity_total gauge
EOF

              for severity in critical high medium low; do
                count=$(jq -Rr --argjson cutoff "$CUTOFF_EPOCH" --arg sev "$severity" \
                  'fromjson? | select(type == "object") | select((((.analysis.original_timestamp) | (try fromdateiso8601 catch 0)) // 0) >= $cutoff and .analysis.severity == $sev)' \
                  "$ANALYSIS_LOG" 2>/dev/null | wc -l)
                echo "backup_errors_by_severity_total{severity=\"$severity\",hostname=\"${config.networking.hostName}\"} $count" >> "$METRICS_TEMP"
              done

              cat >> "$METRICS_TEMP" <<EOF

# HELP backup_error_analysis_last_run_timestamp Last error analysis run timestamp
# TYPE backup_error_analysis_last_run_timestamp gauge
backup_error_analysis_last_run_timestamp{hostname="${config.networking.hostName}"} $TIMESTAMP_UNIX
EOF

              mv "$METRICS_TEMP" "$METRICS_FILE"
            ''}

            # Update state file with max processed event timestamp (atomic write)
            printf "%s\n" "$MAX_TS" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

            echo "Error analysis completed successfully"
          '';
          serviceConfig = {
            Type = "oneshot";
            User = "restic-backup";
            Group = "restic-backup";
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            ReadWritePaths = mkMerge [
              [ cfg.monitoring.logDir "/var/lib/backup" ]
              (mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ])
            ];
          };
        };
      })

      # Documentation and runbook generation service
      (mkIf cfg.documentation.enable {
        backup-documentation = {
          description = "Generate comprehensive backup documentation and runbooks";
          path = with pkgs; [ jq gawk coreutils restic rsync ];
          script = ''
            set -euo pipefail

            DOC_DIR="${cfg.documentation.outputDir}"
            TIMESTAMP=$(date --iso-8601=seconds)
            HOSTNAME="${config.networking.hostName}"

            echo "Generating backup documentation for $HOSTNAME..."

            # Create main documentation file
            cat > "$DOC_DIR/backup-system-overview.md" <<EOF
# Backup System Documentation - $HOSTNAME

**Generated**: $TIMESTAMP
**Host**: $HOSTNAME
**System**: NixOS Restic Backup Configuration

## System Overview

This host runs a comprehensive backup system with the following components:

### Backup Repositories
EOF

            ${concatStringsSep "\n" (mapAttrsToList (repoName: repoConfig: ''
              cat >> "$DOC_DIR/backup-system-overview.md" <<EOF

#### Repository: ${repoName}
- **URL**: ${repoConfig.url}
- **Type**: ${if repoConfig.primary then "Primary" else "Secondary"}
- **Retention**: ${toString cfg.restic.globalSettings.retention.daily}d/${toString cfg.restic.globalSettings.retention.weekly}w/${toString cfg.restic.globalSettings.retention.monthly}m/${toString cfg.restic.globalSettings.retention.yearly}y

EOF
            '') cfg.restic.repositories)}

            cat >> "$DOC_DIR/backup-system-overview.md" <<EOF

### Backup Jobs
EOF

            ${concatStringsSep "\n" (mapAttrsToList (jobName: jobConfig: ''
              cat >> "$DOC_DIR/backup-system-overview.md" <<EOF

#### Job: ${jobName}
- **Schedule**: ${cfg.schedule}
- **Repository**: ${jobConfig.repository}
- **Paths**: ${concatStringsSep ", " jobConfig.paths}
- **Status**: ${if jobConfig.enable then "Enabled" else "Disabled"}

EOF
            '') cfg.restic.jobs)}

            # Add operational procedures
            cat >> "$DOC_DIR/backup-system-overview.md" <<EOF

## Operational Procedures

### Daily Operations
1. Monitor backup status via Prometheus metrics
2. Check systemd service status: \`systemctl status restic-backups-*\`
3. Review backup logs in \`${cfg.monitoring.logDir}\`

### Weekly Tasks
- Verify repository integrity (automated via \`restic-verify-*\` services)
- Review error analysis reports
- Check storage space on backup destinations

### Monthly Tasks
- Test restore procedures (automated via \`restic-restore-test-*\` services)
- Review retention policies
- Audit backup coverage

### Emergency Procedures

#### Complete System Restore
1. Boot from recovery media
2. Install base NixOS system
3. Configure network and SSH access
4. Install Restic: \`nix-shell -p restic\`
5. Restore configuration: \`restic -r REPO_URL restore latest --target /mnt\`

#### Single File Restore
\`\`\`bash
# List snapshots
restic -r REPO_URL snapshots

# Find file in snapshot
restic -r REPO_URL find /path/to/file

# Restore specific file
restic -r REPO_URL restore snapshot_id --target /tmp/restore --include /path/to/file
\`\`\`

### Monitoring and Alerting

#### Service Status
\`\`\`bash
# Check all backup services
systemctl list-units "restic-*" --all

# View logs for specific job
journalctl -u restic-backups-JOB_NAME -f
\`\`\`

#### Error Analysis
- Error analysis runs hourly via \`backup-error-analyzer\` service
- Results logged to \`${cfg.monitoring.logDir}/error-analysis.jsonl\`
- Prometheus metrics available at \`/var/lib/prometheus-node-exporter-text\`

### Configuration Details

#### Security Features
${if cfg.security.enable then ''
- SystemD security hardening enabled
- Network access restricted during backups
- Read-only root filesystem for backup processes
- Audit logging enabled
'' else "- Basic security configuration"}

#### Performance Optimization
- Cache directory: \`${cfg.performance.cacheDir}\`
- Cache size limit: \`${cfg.performance.cacheSizeLimit}\`
${if cfg.performance.ioScheduling.enable then ''
- I/O scheduling: ${cfg.performance.ioScheduling.ioClass} (priority ${toString cfg.performance.ioScheduling.priority})
'' else ""}

#### Verification and Testing
${if cfg.verification.enable then ''
- Repository verification: ${cfg.verification.schedule}
- Data integrity: ${if cfg.verification.checkData then "Full" else "Metadata only"}
'' else ""}
${if cfg.restoreTesting.enable then ''
- Restore testing: ${cfg.restoreTesting.schedule}
- Sample size: ${toString cfg.restoreTesting.sampleFiles} files
'' else ""}

EOF

            # Generate troubleshooting guide
            cat > "$DOC_DIR/troubleshooting-guide.md" <<EOF
# Backup System Troubleshooting Guide - $HOSTNAME

**Generated**: $TIMESTAMP

## Common Issues and Solutions

### Backup Job Failures

#### Network Issues
**Symptoms**: Connection timeouts, DNS resolution failures
**Solutions**:
- Check network connectivity to backup destination
- Verify DNS resolution: \`nslookup backup-server\`
- Test repository access: \`restic -r REPO_URL snapshots\`

#### Storage Issues
**Symptoms**: "No space left on device", write errors
**Solutions**:
- Check source disk space: \`df -h\`
- Check destination storage: \`restic -r REPO_URL stats\`
- Clean old snapshots: \`restic -r REPO_URL forget --prune\`

#### Permission Issues
**Symptoms**: "Permission denied", "Access forbidden"
**Solutions**:
- Verify backup user permissions
- Check repository permissions
- Validate credential files exist and are readable

### Repository Corruption
**Symptoms**: "repository contains errors", "pack not found"
**Solutions**:
1. Run repository check: \`restic -r REPO_URL check\`
2. Attempt repair: \`restic -r REPO_URL check --read-data\`
3. If unrepairable, restore from secondary repository

### Performance Issues
**Symptoms**: Slow backups, high CPU/memory usage
**Solutions**:
- Adjust read concurrency: Modify \`globalSettings.readConcurrency\`
- Check I/O scheduling configuration
- Monitor system resources during backup windows
- Consider increasing cache size limit

### Service Management

#### Restarting Services
\`\`\`bash
# Restart specific backup job
systemctl restart restic-backups-JOB_NAME

# Restart verification service
systemctl restart restic-verify-REPO_NAME

# Check service status
systemctl status restic-backups-*
\`\`\`

#### Viewing Logs
\`\`\`bash
# Real-time logs for all backup services
journalctl -u "restic-*" -f

# Structured logs (JSON format)
tail -f ${cfg.monitoring.logDir}/*.jsonl | jq

# Error analysis logs
tail -f ${cfg.monitoring.logDir}/error-analysis.jsonl | jq
\`\`\`

### Emergency Contacts and Escalation
1. Check automated alerting (ntfy, healthchecks.io)
2. Review Prometheus metrics for system health
3. Consult backup documentation in \`$DOC_DIR\`

EOF

            ${optionalString cfg.documentation.includeMetrics ''
              # Generate metrics documentation if enabled
              cat > "$DOC_DIR/metrics-reference.md" <<EOF
# Backup System Metrics Reference - $HOSTNAME

**Generated**: $TIMESTAMP

## Available Metrics

All metrics are exported via Prometheus Node Exporter textfile collector.
**Metrics Directory**: \`${cfg.monitoring.prometheus.metricsDir}\`

### Backup Job Metrics
- \`restic_backup_duration_seconds\` - Backup job duration
- \`restic_backup_last_run_timestamp\` - Last successful backup timestamp
- \`restic_backup_files_total\` - Total files processed
- \`restic_backup_size_bytes\` - Total backup size in bytes

### Repository Health Metrics
- \`restic_verification_duration_seconds\` - Repository verification duration
- \`restic_verification_last_run_timestamp\` - Last verification timestamp

### Error Analysis Metrics
- \`backup_errors_by_category_total\` - Error counts by category (network, storage, permission, etc.)
- \`backup_errors_by_severity_total\` - Error counts by severity (critical, high, medium, low)
- \`backup_error_analysis_last_run_timestamp\` - Last error analysis run

### Restore Testing Metrics
- \`restic_restore_test_duration_seconds\` - Restore test duration
- \`restic_restore_test_last_run_timestamp\` - Last restore test timestamp
- \`restic_restore_test_success\` - Restore test success (1=success, 0=failure)

## Querying Examples

### Prometheus Queries
\`\`\`promql
# Backup job success rate over 24 hours
rate(restic_backup_duration_seconds[24h])

# Failed backups in last 24 hours
increase(backup_errors_by_severity_total{severity="critical"}[24h])

# Average backup duration by job
avg(restic_backup_duration_seconds) by (job_name)
\`\`\`

### Alert Rules
Example Prometheus alert rules for backup monitoring:

\`\`\`yaml
groups:
- name: backup.rules
  rules:
  - alert: BackupJobFailed
    expr: increase(backup_errors_by_severity_total{severity=~"critical|high"}[1h]) > 0
    for: 0m
    labels:
      severity: critical
    annotations:
      summary: "Backup job failed on {{ \$labels.hostname }}"

  - alert: BackupJobMissing
    expr: time() - restic_backup_last_run_timestamp > 86400
    for: 0m
    labels:
      severity: warning
    annotations:
      summary: "Backup job hasn't run for 24+ hours on {{ \$labels.hostname }}"
\`\`\`

EOF
            ''}

            # Create quick reference guide
            cat > "$DOC_DIR/quick-reference.md" <<EOF
# Backup System Quick Reference - $HOSTNAME

**Generated**: $TIMESTAMP

## Quick Commands

### Check Status
\`\`\`bash
systemctl status restic-backups-*                    # All backup jobs
journalctl -u restic-backups-* --since "1 hour ago"  # Recent logs
\`\`\`

### Manual Operations
\`\`\`bash
# Force backup run
systemctl start restic-backups-JOB_NAME

# Check repository
restic -r REPO_URL check

# List snapshots
restic -r REPO_URL snapshots

# Repository statistics
restic -r REPO_URL stats
\`\`\`

### Emergency Procedures
\`\`\`bash
# Stop all backups
systemctl stop restic-backups-*

# Restore single file
restic -r REPO_URL restore latest --target /tmp --include /path/to/file

# Emergency repository access
export RESTIC_REPOSITORY=REPO_URL
export RESTIC_PASSWORD_FILE=/path/to/password
restic snapshots
\`\`\`

## Configuration Locations
- Main config: \`/etc/nixos/configuration.nix\`
- Logs: \`${cfg.monitoring.logDir}\`
- Cache: \`${cfg.performance.cacheDir}\`
- Docs: \`$DOC_DIR\`

EOF

            echo "Documentation generated successfully in $DOC_DIR"

            # Copy documentation to NAS for DR access
            ${concatStringsSep "\n" (mapAttrsToList (repoName: repoConfig:
              optionalString (repoConfig.primary && (hasPrefix "/mnt/" repoConfig.url || hasPrefix "nfs://" repoConfig.url)) ''
                # Copy to sibling DR directory for immediate disaster recovery access
                # If repo is at /mnt/nas-backup, DR docs go to /mnt/nas-docs/dr/
                REPO_BASE=$(dirname "${repoConfig.url}")
                NAS_DOCS_DIR="$REPO_BASE/nas-docs/dr"
                if [ -d "$REPO_BASE" ]; then
                  echo "Copying documentation to NAS: $NAS_DOCS_DIR"
                  # Create DR directory with proper ownership if it doesn't exist
                  if ! [ -d "$NAS_DOCS_DIR" ]; then
                    ${pkgs.coreutils}/bin/mkdir -p "$NAS_DOCS_DIR" 2>/dev/null || true
                  fi
                  if [ -d "$NAS_DOCS_DIR" ]; then
                    ${pkgs.rsync}/bin/rsync -a --delete "$DOC_DIR/" "$NAS_DOCS_DIR/" && \
                      echo "Documentation copied to NAS successfully" || \
                      echo "Warning: Could not copy documentation to NAS"
                  else
                    echo "Warning: NAS documentation directory not accessible: $NAS_DOCS_DIR"
                  fi
                else
                  echo "Warning: NAS mount base directory not available: $REPO_BASE"
                fi
              ''
            ) cfg.restic.repositories)}

            # Update generation timestamp for metrics
            ${optionalString cfg.monitoring.prometheus.enable ''
              METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/backup_documentation.prom"
              TIMESTAMP_UNIX=$(date +%s)

              cat > "$METRICS_FILE" <<EOF
# HELP backup_documentation_last_generated_timestamp Last documentation generation timestamp
# TYPE backup_documentation_last_generated_timestamp gauge
backup_documentation_last_generated_timestamp{hostname="$HOSTNAME"} $TIMESTAMP_UNIX
EOF
            ''}
          '';
          serviceConfig = {
            Type = "oneshot";
            User = "restic-backup";
            Group = "restic-backup";
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            ReadWritePaths = mkMerge [
              [ cfg.documentation.outputDir ]
              (mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ])
              # Allow write access to NAS docs directory for primary repositories
              (map (repoConfig: "${dirOf repoConfig.url}/nas-docs")
                (filter (repoConfig: repoConfig.primary && (hasPrefix "/mnt/" repoConfig.url || hasPrefix "nfs://" repoConfig.url))
                  (attrValues cfg.restic.repositories)))
            ];
          };
        };
      })

      # Override restic backup services to add OnFailure handlers for immediate alerting
      (mkMerge (mapAttrsToList (jobName: jobConfig:
        mkIf (jobConfig.enable && cfg.monitoring.onFailure.enable) {
          "restic-backups-${jobName}" = {
            unitConfig = {
              # Use generic notification dispatcher if centralized notifications enabled
              # Pass %n (unit name) so dispatcher can extract logs and job name
              OnFailure = mkIf (hasCentralizedNotifications && (notificationsCfg.templates.backup-failure.enable or false))
                [ "notify@backup-failure:%n.service" ];
            };
          };
        }
      ) cfg.restic.jobs))
    ];

    # Group target for all restic backup services to enable coordination with other subsystems
    systemd.targets.restic-backups = {
      description = "Restic Backup Services";
      # No automatic start; used for Conflicts/PartOf grouping only
    };

    # Create required directories for Phase 3 features
    systemd.tmpfiles.rules = mkMerge [
      # Base directory for backup state files
      [
        "d /var/lib/backup 0755 restic-backup restic-backup -"
      ]
      (mkIf cfg.monitoring.enable [
        "d ${cfg.monitoring.logDir} 0755 restic-backup restic-backup -"
      ])
      # Note: Metrics directory creation handled by monitoring.nix module
      # Do not create duplicate tmpfiles rules here to avoid conflicts
      (mkIf cfg.restoreTesting.enable [
        "d ${cfg.restoreTesting.testDir} 0700 restic-backup restic-backup -"
      ])
      (mkIf cfg.documentation.enable [
        "d ${cfg.documentation.outputDir} 0755 restic-backup restic-backup -"
      ])
      [
        "d ${cfg.performance.cacheDir} 0700 restic-backup restic-backup -"
      ]
    ];

    # Performance optimization: Restic cache configuration
    # Note: RESTIC_COMPRESSION and RESTIC_READ_CONCURRENCY are passed via extraBackupArgs
    # in services.restic.backups instead of as environment variables, as restic doesn't
    # honor them when set globally.
    environment.variables = mkIf cfg.restic.enable {
      RESTIC_CACHE_DIR = cfg.performance.cacheDir;
    };

    # Use built-in NixOS restic service - truxnell's approach with Phase 3 enhancements
    services.restic.backups = mkMerge (mapAttrsToList (jobName: jobConfig:
      mkIf jobConfig.enable (
        let
          repo = cfg.restic.repositories.${jobConfig.repository} or {};
          # When ZFS snapshots are enabled, we'll use dynamicFilesFrom to read paths at runtime
          # This allows us to use snapshot paths with the runtime-determined snapshot name
          actualPaths = if cfg.zfs.enable
            then [] # Empty, will use dynamicFilesFrom instead
            else jobConfig.paths;
        in {
          "${jobName}" = {
            paths = actualPaths;
            dynamicFilesFrom = if cfg.zfs.enable
              then "cat /run/restic-backup/${jobName}-paths.txt"
              else null;
            repository = repo.url;
            passwordFile = repo.passwordFile or null;
            environmentFile = repo.environmentFile or null;
            exclude = jobConfig.excludePatterns;
            initialize = true;
            # Pass compression and read concurrency as backup arguments instead of env vars
            extraBackupArgs = [
              "--compression=${cfg.restic.globalSettings.compression}"
              "--read-concurrency=${toString cfg.restic.globalSettings.readConcurrency}"
            ];
            # Note: Unit-level coordination is set in systemd.services.restic-backups-${jobName}
            timerConfig = {
              # Stagger timer slightly to avoid herd effects; runs shortly after Sanoid
              OnCalendar = cfg.schedule;
              Persistent = true;
              RandomizedDelaySec = "10m";
            };
            pruneOpts = [
              "--keep-daily ${toString cfg.restic.globalSettings.retention.daily}"
              "--keep-weekly ${toString cfg.restic.globalSettings.retention.weekly}"
              "--keep-monthly ${toString cfg.restic.globalSettings.retention.monthly}"
              "--keep-yearly ${toString cfg.restic.globalSettings.retention.yearly}"
            ];
            backupPrepareCommand = ''
              ${optionalString cfg.monitoring.enable ''
                # Capture start time for duration calculation
                ${pkgs.coreutils}/bin/mkdir -p /run/restic-backups-${jobName}
                ${pkgs.coreutils}/bin/date +%s > /run/restic-backups-${jobName}/start-time
              ''}
              ${optionalString cfg.zfs.enable ''
                set -euo pipefail

                # Cleanup function to release holds on prepare failure
                cleanup_prepare_holds() {
                  local HOLD_TAG="restic-${jobName}"
                  if [ -f /run/restic-backup/${jobName}-snapshots.txt ]; then
                    echo "ERROR: Prepare failed, releasing any holds placed..." >&2
                    while IFS= read -r snapshot; do
                      if [ -n "$snapshot" ]; then
                        ${config.boot.zfs.package}/bin/zfs release "$HOLD_TAG" "$snapshot" 2>/dev/null || true
                      fi
                    done < /run/restic-backup/${jobName}-snapshots.txt
                    rm -f /run/restic-backup/${jobName}-snapshots.txt
                  fi
                }
                trap cleanup_prepare_holds ERR

                # STALE HOLD CLEANUP: Release any orphaned holds from previous crashed runs
                # This prevents leaked holds from blocking Sanoid's pruning operations
                # Note: We check hold timestamp, not snapshot creation time, to identify truly stale holds
                # Safety: Runs inside this job's prepare phase; only releases holds older than 24h with
                # this job's specific tag, preventing interference with currently running backups.
                echo "Checking for stale ZFS holds from previous runs..."
                HOLD_TAG="restic-${jobName}"
                STALE_THRESHOLD=$(($(${pkgs.coreutils}/bin/date +%s) - 86400))  # 24 hours ago
                SCANNED_DATASETS=""  # Track datasets to avoid duplicate scans

                ${concatMapStringsSep "\n" (path: ''
                  # Find dataset for this path to check its holds
                  DATASET=$(${config.boot.zfs.package}/bin/zfs list -H -o name,mountpoint -t filesystem | ${pkgs.gawk}/bin/awk -v p="${path}" '
                    {
                      mp=$2
                      if (p == mp || (index(p, mp) == 1 && (substr(p, length(mp)+1, 1) == "/" || mp == "/"))) {
                        if (length(mp) > max) { max = length(mp); best = $1 }
                      }
                    }
                    END { if (best) print best }
                  ')

                  if [ -n "$DATASET" ]; then
                    # Skip if we've already scanned this dataset (deduplicate)
                    if ! printf "%s\n" "$SCANNED_DATASETS" | ${pkgs.gnugrep}/bin/grep -Fxq "$DATASET" 2>/dev/null; then
                      SCANNED_DATASETS="$SCANNED_DATASETS"$'\n'"$DATASET"

                      # Check all snapshots on this dataset for stale holds with our tag
                      # Format: NAME<TAB>TAG<TAB>CREATED (NAME is filesystem@snapshot)
                      # Pre-filter with grep to reduce awk workload
                      # Wrapped in subshell to disable pipefail - empty results are expected/normal
                      (
                        set +o pipefail
                        ${config.boot.zfs.package}/bin/zfs holds -H -r "$DATASET" 2>/dev/null | \
                          ${pkgs.gnugrep}/bin/grep -F "$HOLD_TAG" | \
                          ${pkgs.gawk}/bin/awk -F "\t" -v tag="$HOLD_TAG" -v threshold="$STALE_THRESHOLD" '
                          $2 == tag {
                            # Parse hold creation timestamp with explicit locale/timezone
                            # Format: "Mon Oct 14 02:05:23 2025"
                            cmd = "LC_ALL=C TZ=UTC date -d \"" $3 "\" +%s 2>/dev/null"
                            cmd | getline hold_epoch
                            close(cmd)

                            # Validate numeric and compare
                            if (hold_epoch ~ /^[0-9]+$/ && hold_epoch < threshold) {
                              print $1
                            }
                          }
                        ' | while IFS= read -r snap_with_hold; do
                          if [ -n "$snap_with_hold" ]; then
                            echo "Releasing stale hold '$HOLD_TAG' on $snap_with_hold (hold older than 24h)"
                            if ! ${config.boot.zfs.package}/bin/zfs release "$HOLD_TAG" "$snap_with_hold" 2>/dev/null; then
                              echo "WARNING: Could not release hold '$HOLD_TAG' on $snap_with_hold (already released or permission denied)" >&2
                            fi
                          fi
                        done
                      )
                    fi
                  fi
                '') jobConfig.paths}

                # Resolve paths to Sanoid snapshots via .zfs/snapshot
                ${pkgs.coreutils}/bin/mkdir -p /run/restic-backup
                : > /run/restic-backup/${jobName}-paths.txt  # Truncate file
                : > /run/restic-backup/${jobName}-snapshots.txt  # Truncate file

                # Dynamically map each backup path to its latest Sanoid snapshot
                ${concatMapStringsSep "\n" (path: ''
                  # Discover the ZFS dataset for this path using longest-prefix match
                  DATASET=$(${config.boot.zfs.package}/bin/zfs list -H -o name,mountpoint -t filesystem | ${pkgs.gawk}/bin/awk -v p="${path}" '
                    {
                      mp=$2
                      # Match if path equals mountpoint OR path starts with mountpoint/
                      if (p == mp || (index(p, mp) == 1 && (substr(p, length(mp)+1, 1) == "/" || mp == "/"))) {
                        # Keep the longest matching mountpoint
                        if (length(mp) > max) { max = length(mp); best = $1 }
                      }
                    }
                    END { if (best) print best }
                  ')

                  if [ -n "$DATASET" ]; then
                    # Get the dataset mountpoint
                    MOUNTPOINT=$(${config.boot.zfs.package}/bin/zfs list -H -o mountpoint "$DATASET")

                    # Find the latest Sanoid snapshot for this dataset
                    LATEST_SNAP=$(${config.boot.zfs.package}/bin/zfs list -H -t snapshot -o name -s creation "$DATASET" | ${pkgs.coreutils}/bin/tail -n 1)

                    if [ -n "$LATEST_SNAP" ]; then
                      # Extract snapshot name (everything after @)
                      SNAPNAME="''${LATEST_SNAP#*@}"

                      # Place a ZFS hold to prevent Sanoid from pruning this snapshot during backup
                      # CRITICAL: Make hold placement fail-fast to prevent inconsistent backups
                      # IDEMPOTENCY: Check if hold already exists to avoid duplicate hold errors
                      HOLD_TAG="restic-${jobName}"

                      # Check if hold already exists using proper tab-separated parsing
                      if ${config.boot.zfs.package}/bin/zfs holds -H "$LATEST_SNAP" 2>/dev/null \
                        | ${pkgs.gawk}/bin/awk -F "\t" -v tag="$HOLD_TAG" '$2==tag {found=1} END {exit found?0:1}'; then
                        echo "ZFS hold '$HOLD_TAG' already exists on $LATEST_SNAP (idempotent)"
                      else
                        echo "Placing ZFS hold '$HOLD_TAG' on $LATEST_SNAP"
                        if ! ${config.boot.zfs.package}/bin/zfs hold "$HOLD_TAG" "$LATEST_SNAP"; then
                          echo "ERROR: Failed to place ZFS hold on $LATEST_SNAP" >&2
                          exit 1
                        fi
                      fi

                      # Verify snapshot still exists after hold (defensive against concurrent prune)
                      if ! ${config.boot.zfs.package}/bin/zfs list -H -t snapshot "$LATEST_SNAP" >/dev/null 2>&1; then
                        echo "ERROR: Snapshot $LATEST_SNAP disappeared before hold took effect" >&2
                        exit 1
                      fi

                      # Store snapshot name for cleanup
                      echo "$LATEST_SNAP" >> /run/restic-backup/${jobName}-snapshots.txt

                      # Calculate relative path from mountpoint
                      REL=$(${pkgs.coreutils}/bin/realpath -m --relative-to="$MOUNTPOINT" "${path}")

                      # Build snapshot path: mountpoint/.zfs/snapshot/snapname/relative-path
                      if [ "$REL" = "." ]; then
                        SNAP_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAPNAME"
                      else
                        SNAP_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAPNAME/$REL"
                      fi

                      echo "$SNAP_PATH" >> /run/restic-backup/${jobName}-paths.txt
                      echo "Mapped ${path} -> $SNAP_PATH (dataset: $DATASET, snapshot: $SNAPNAME)"
                    else
                      # CRITICAL: Fail backup if snapshot is missing to avoid inconsistent backups
                      echo "ERROR: No snapshots found for dataset $DATASET" >&2
                      echo "ERROR: Cannot proceed with consistent backup. Check Sanoid service: systemctl status sanoid.service" >&2
                      exit 1
                    fi
                  else
                    # Path is not on ZFS - this is acceptable for non-ZFS paths
                    # (e.g., /boot, /tmp, or explicitly mounted non-ZFS filesystems)
                    echo "INFO: Path ${path} is not on a ZFS dataset, using live path" >&2
                    echo "${path}" >> /run/restic-backup/${jobName}-paths.txt
                  fi
                '') jobConfig.paths}

                # Validate that paths file is not empty
                if ! [ -s /run/restic-backup/${jobName}-paths.txt ]; then
                  echo "ERROR: No paths resolved for job ${jobName}" >&2
                  exit 1
                fi

                echo "Backup will use snapshot paths:"
                ${pkgs.coreutils}/bin/cat /run/restic-backup/${jobName}-paths.txt
              ''}
              ${optionalString cfg.validation.preFlightChecks.enable ''
                # Pre-flight validation checks
                echo "Running pre-flight validation checks..."

                # Check available space
                AVAILABLE=$(${pkgs.coreutils}/bin/df --output=avail --block-size=1G ${cfg.performance.cacheDir} | ${pkgs.coreutils}/bin/tail -1)
                MIN_SPACE=$(echo "${cfg.validation.preFlightChecks.minFreeSpace}" | ${pkgs.gnused}/bin/sed 's/[^0-9]//g')
                if [ "$AVAILABLE" -lt "$MIN_SPACE" ]; then
                  echo "ERROR: Insufficient disk space. Available: ''${AVAILABLE}G, Required: ''${MIN_SPACE}G"
                  exit 1
                fi

                ${optionalString ((repo.environmentFile or null) != null) ''
                  # Validate and source environment file for restic credentials
                  if [ ! -f "${repo.environmentFile}" ]; then
                    echo "ERROR: Environment file not found: ${repo.environmentFile}"
                    exit 1
                  fi
                  if [ ! -r "${repo.environmentFile}" ]; then
                    echo "ERROR: Environment file not readable: ${repo.environmentFile}"
                    exit 1
                  fi
                  set -a
                  . "${repo.environmentFile}"
                  set +a
                ''}

                # Test repository connectivity
                timeout ${toString cfg.validation.preFlightChecks.networkTimeout} ${pkgs.restic}/bin/restic \
                  -r "${repo.url}" \
                  --password-file "${repo.passwordFile}" \
                  snapshots --latest 1 > /dev/null || {
                  echo "ERROR: Cannot connect to repository ${repo.url}"
                  exit 1
                }

                echo "Pre-flight checks passed successfully"
              ''}
              ${optionalString cfg.monitoring.enable ''
                # Initialize structured logging
                TIMESTAMP=$(${pkgs.coreutils}/bin/date --iso-8601=seconds)
                LOG_FILE="${cfg.monitoring.logDir}/backup-jobs.jsonl"

                ${pkgs.jq}/bin/jq -n \
                  --arg timestamp "$TIMESTAMP" \
                  --arg job "${jobName}" \
                  --arg repo "${repo.url}" \
                  --arg event "backup_start" \
                  --arg hostname "${config.networking.hostName}" \
                  '{
                    timestamp: $timestamp,
                    event: $event,
                    job_name: $job,
                    repository: $repo,
                    hostname: $hostname
                  }' >> "$LOG_FILE" || true
              ''}
            '';
            backupCleanupCommand = ''
              ${optionalString cfg.zfs.enable ''
                # Release ZFS holds placed during backup preparation
                HOLD_TAG="restic-${jobName}"
                if [ -f /run/restic-backup/${jobName}-snapshots.txt ]; then
                  while IFS= read -r snapshot; do
                    if [ -n "$snapshot" ]; then
                      echo "Releasing ZFS hold '$HOLD_TAG' on $snapshot"
                      if ! ${config.boot.zfs.package}/bin/zfs release "$HOLD_TAG" "$snapshot" 2>/dev/null; then
                        echo "WARNING: Failed to release hold on $snapshot (may have been already released)" >&2
                        ${optionalString cfg.monitoring.prometheus.enable ''
                          # Emit metric on hold release failure for monitoring
                          mkdir -p ${cfg.monitoring.prometheus.metricsDir}
                          echo "restic_hold_release_failure{backup_job=\"${jobName}\",snapshot=\"$snapshot\",host=\"${config.networking.hostName}\"} 1" \
                            >> ${cfg.monitoring.prometheus.metricsDir}/backup_internal.prom || true
                        ''}
                      fi
                    fi
                  done < /run/restic-backup/${jobName}-snapshots.txt
                  rm -f /run/restic-backup/${jobName}-snapshots.txt
                fi
              ''}
              ${optionalString cfg.monitoring.enable ''
                # Log backup completion and export metrics
                TIMESTAMP=$(${pkgs.coreutils}/bin/date --iso-8601=seconds)
                LOG_FILE="${cfg.monitoring.logDir}/backup-jobs.jsonl"
                END_TIME=$(${pkgs.coreutils}/bin/date +%s)
                START_TIME=$(${pkgs.coreutils}/bin/cat /run/restic-backups-${jobName}/start-time 2>/dev/null || echo "$END_TIME")
                DURATION=$((END_TIME - START_TIME))

                ${pkgs.jq}/bin/jq -n \
                  --arg timestamp "$TIMESTAMP" \
                  --arg job "${jobName}" \
                  --arg repo "${repo.url}" \
                  --arg event "backup_complete" \
                  --arg hostname "${config.networking.hostName}" \
                  --arg duration "$DURATION" \
                  '{
                    timestamp: $timestamp,
                    event: $event,
                    job_name: $job,
                    repository: $repo,
                    hostname: $hostname,
                    duration_seconds: ($duration | tonumber)
                  }' >> "$LOG_FILE" || true
              ''}
              ${optionalString cfg.monitoring.prometheus.enable ''
                # Export Prometheus metrics
                METRICS_FILE="${cfg.monitoring.prometheus.metricsDir}/restic_backup_${jobName}.prom"
                METRICS_TEMP="$METRICS_FILE.tmp"
                TIMESTAMP=$(${pkgs.coreutils}/bin/date +%s)

                cat > "$METRICS_TEMP" <<EOF
# HELP restic_backup_duration_seconds Duration of backup job in seconds
# TYPE restic_backup_duration_seconds gauge
restic_backup_duration_seconds{backup_job="${jobName}",repository="${jobConfig.repository}",hostname="${config.networking.hostName}"} $DURATION

# HELP restic_backup_last_success_timestamp Last successful backup timestamp
# TYPE restic_backup_last_success_timestamp gauge
restic_backup_last_success_timestamp{backup_job="${jobName}",repository="${jobConfig.repository}",hostname="${config.networking.hostName}"} $TIMESTAMP

# HELP restic_backup_status Backup job status (1=success, 0=failure)
# TYPE restic_backup_status gauge
restic_backup_status{backup_job="${jobName}",repository="${jobConfig.repository}",hostname="${config.networking.hostName}"} 1
EOF
                # Export parity metrics with restic-exporter: timestamp, size, files
                # Source repository environment if provided
                ${optionalString ((repo.environmentFile or null) != null) ''
                  if [ -f "${repo.environmentFile}" ]; then
                    set -a
                    . "${repo.environmentFile}"
                    set +a
                  fi
                ''}
                # Collect last backup stats (size/files) and canonical timestamp metric
                STATS_JSON=$(${pkgs.restic}/bin/restic -r "${repo.url}" --password-file "${repo.passwordFile}" \
                  stats --json --mode restore-size --latest 2>/dev/null || echo "")
                if [ -n "$STATS_JSON" ]; then
                  SIZE_BYTES=$(${pkgs.jq}/bin/jq -r '.total_size // .total_bytes // 0' <<< "$STATS_JSON")
                  FILES_TOTAL=$(${pkgs.jq}/bin/jq -r '.total_file_count // .files // 0' <<< "$STATS_JSON")
                  # Append exporter-compatible metrics
                  echo "# HELP restic_backup_timestamp Timestamp of the last backup" >> "$METRICS_TEMP"
                  echo "# TYPE restic_backup_timestamp gauge" >> "$METRICS_TEMP"
                  echo "restic_backup_timestamp{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $TIMESTAMP" >> "$METRICS_TEMP"
                  echo "# HELP restic_backup_size_total Total size of backup in bytes" >> "$METRICS_TEMP"
                  echo "# TYPE restic_backup_size_total counter" >> "$METRICS_TEMP"
                  echo "restic_backup_size_total{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $SIZE_BYTES" >> "$METRICS_TEMP"
                  echo "# HELP restic_backup_files_total Number of files in the backup" >> "$METRICS_TEMP"
                  echo "# TYPE restic_backup_files_total counter" >> "$METRICS_TEMP"
                  echo "restic_backup_files_total{backup_job=\"${jobName}\",repository=\"${jobConfig.repository}\",hostname=\"${config.networking.hostName}\"} $FILES_TOTAL" >> "$METRICS_TEMP"
                fi
                ${pkgs.coreutils}/bin/mv "$METRICS_TEMP" "$METRICS_FILE"
              ''}
            '';
          };
        })
    ) cfg.restic.jobs);


    # Systemd timers for verification and restore testing
    systemd.timers = mkMerge [
      # Repository verification timers
      (mkMerge (mapAttrsToList (repoName: repoConfig:
        mkIf cfg.verification.enable {
          "restic-check-${repoName}" = {
            description = "Timer for restic repository integrity check (${repoName})";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = cfg.verification.schedule;
              Persistent = true;
              RandomizedDelaySec = "1h";
            };
          };
        }
      ) cfg.restic.repositories))

      # Repository restore testing timers
      (mkMerge (mapAttrsToList (repoName: repoConfig:
        mkIf cfg.restoreTesting.enable {
          "restic-restore-test-${repoName}" = {
            description = "Timer for automated restore testing (${repoName})";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = cfg.restoreTesting.schedule;
              Persistent = true;
              RandomizedDelaySec = "2h";
            };
          };
        }
      ) cfg.restic.repositories))

      # Error analysis timer
      (mkIf cfg.monitoring.errorAnalysis.enable {
        backup-error-analyzer = {
          description = "Timer for backup error analysis";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "hourly";
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        };
      })

      # Documentation generation timer
      (mkIf cfg.documentation.enable {
        backup-documentation = {
          description = "Timer for backup documentation generation";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };
      })
    ];

    # Enhanced validation assertions for Phase 3
    assertions = [
      {
        assertion = cfg.zfs.enable -> config.boot.supportedFilesystems.zfs or false;
        message = "ZFS support must be enabled in boot.supportedFilesystems when using ZFS backup integration";
      }
      {
        assertion = cfg.restic.enable -> (cfg.restic.repositories != {});
        message = "At least one Restic repository must be configured when Restic backup is enabled";
      }
      {
        assertion = cfg.monitoring.healthchecks.enable -> (cfg.monitoring.healthchecks.uuidFile != null);
        message = "Healthchecks.io UUID file must be specified when Healthchecks monitoring is enabled";
      }
      {
        assertion = cfg.verification.enable -> cfg.restic.enable;
        message = "Repository verification requires Restic backup to be enabled";
      }
      {
        assertion = cfg.restoreTesting.enable -> cfg.restic.enable;
        message = "Restore testing requires Restic backup to be enabled";
      }
      {
        assertion = cfg.monitoring.prometheus.enable -> config.services.prometheus.exporters.node.enable or false;
        message = "Prometheus metrics export requires Node Exporter to be enabled";
      }
      {
        assertion = cfg.validation.enable -> cfg.restic.enable;
        message = "Configuration validation requires Restic backup to be enabled";
      }
      {
        assertion = cfg.performance.ioScheduling.enable -> (elem cfg.performance.ioScheduling.ioClass ["idle" "best-effort" "realtime"]);
        message = "Invalid I/O scheduling class specified";
      }
      {
        assertion = cfg.security.enable -> cfg.restic.enable;
        message = "Security hardening requires Restic backup to be enabled";
      }
      {
        assertion = cfg.monitoring.onFailure.enable -> cfg.monitoring.enable;
        message = "OnFailure notifications require monitoring to be enabled";
      }
      {
        assertion = cfg.monitoring.errorAnalysis.enable -> cfg.monitoring.enable;
        message = "Error analysis requires monitoring to be enabled";
      }
    ] ++ (mapAttrsToList (jobName: jobConfig: {
      assertion = jobConfig.enable -> (hasAttr jobConfig.repository cfg.restic.repositories);
      message = "Backup job '${jobName}' references unknown repository '${jobConfig.repository}'";
    }) cfg.restic.jobs) ++ (mapAttrsToList (jobName: jobConfig:
      let
        repo = cfg.restic.repositories.${jobConfig.repository} or {};
      in {
        assertion = jobConfig.enable && (repo.environmentFile or null) != null ->
          (builtins.match ".*[[:space:]].*" (toString repo.environmentFile) == null);
        message = "Backup job '${jobName}': environmentFile path '${toString (repo.environmentFile or "null")}' contains whitespace which may cause parsing errors";
      }
    ) cfg.restic.jobs) ++ (mapAttrsToList (jobName: jobConfig: {
      assertion = jobConfig.enable && (jobConfig.paths != []) ->
        (builtins.all (path: builtins.match "^/.*" path != null) jobConfig.paths);
      message = "Backup job '${jobName}': All backup paths must be absolute paths starting with /";
    }) cfg.restic.jobs) ++ (mapAttrsToList (jobName: jobConfig:
      let
        repo = cfg.restic.repositories.${jobConfig.repository} or {};
      in {
        assertion = jobConfig.enable ->
          ((repo.passwordFile or null) != null || (repo.environmentFile or null) != null);
        message = "Backup job '${jobName}': Repository must have either passwordFile or environmentFile configured for authentication";
      }
    ) cfg.restic.jobs);
  };
}
