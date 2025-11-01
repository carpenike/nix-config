{ config, lib, ... }:

# Forge Backup Configuration
#
# PostgreSQL backups are handled by pgBackRest (see postgresql.nix and default.nix)
# - Application-consistent backups with Point-in-Time Recovery (PITR)
# - Multi-repo: Local NFS (repo1) + Offsite R2 (repo2)
# - Integrated with monitoring and Prometheus metrics
# - Archive-async with local spool for high availability
#
# PostgreSQL Backup Strategy:
# - pgBackRest repo1 (NFS): Full/diff/incr backups + continuous WAL archiving (primary recovery)
# - pgBackRest repo2 (R2): Full/diff/incr backups ONLY - pure DR repository (no continuous WALs)
#   * RPO for R2 recovery: ~1 hour (last incremental backup)
#   * Design rationale: Cost optimization, operational simplicity, fast local recovery priority
# - ZFS snapshots: Service data only (tank/services excluding PostgreSQL PGDATA)
# - ZFS replication: Service data to nas-1 every 15 minutes (configured in default.nix, excludes PostgreSQL)
#
# This file manages Restic backups for non-database services:
# - System state (/home, /persist)
# - Service configurations
# - Documentation
#
# PostgreSQL Recovery Process:
# PostgreSQL backups are now handled entirely by pgBackRest (not Restic)
# For recovery procedures, see: /Users/ryan/src/nix-config/docs/postgresql-pitr-guide.md
# WAL archive is managed by pgBackRest at: /mnt/nas-postgresql/pgbackrest/archive/
# No separate WAL restoration needed - pgBackRest handles this automatically
#
# Setup Requirements:
# 1. Create Cloudflare R2 bucket: "nix-homelab-backups"
# 2. Generate R2 API token (read/write access)
# 3. Add to secrets.sops.yaml:
#    restic/r2-env: |
#      AWS_ACCESS_KEY_ID=<your_key>
#      AWS_SECRET_ACCESS_KEY=<your_secret>
# 4. Deploy configuration and verify first backup succeeds

let
  # Reference centralized primary backup repository config from default.nix
  # See hosts/forge/default.nix for the single source of truth
  primaryRepoName = "nas-primary";
  primaryRepoUrl = "/mnt/nas-backup";
  primaryRepoPasswordFile = config.sops.secrets."restic/password".path;

  # Cloudflare R2 offsite repository configuration (DRY principle)
  r2OffsetUrl = "s3:https://21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
in
{
  config = {
    # Note: restic-backup user/group created by backup module
    # (hosts/_modules/nixos/backup.nix - no need to duplicate here)

    # Mount NFS shares from nas-1 for backups
    # Restic backup storage (non-database data)
    # Prefer declarative fileSystems with systemd automount and explicit network dependency
    fileSystems."/mnt/nas-backup" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/restic";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "noauto"                          # don’t mount at boot; automount will trigger on access
        "_netdev"                         # mark as network device
        "x-systemd.automount"             # create/enable automount unit
        "x-systemd.idle-timeout=600"      # unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"     # fail fast if NAS is down
        "x-systemd.force-unmount=true"    # force unmount on shutdown to avoid hangs
        "x-systemd.after=network-online.target"
        "x-systemd.requires=network-online.target"
      ];
    };

    # Static systemd.mount removed; rely on fileSystems automount and RequiresMountsFor in dependent services.

    # PostgreSQL backups via pgBackRest (separate mount for isolation)
    # Hardened for pgBackRest WAL archiving reliability
    # CRITICAL: No automount - must be always available for:
    #   - postgresql-preseed service (runs early, namespace isolated)
    #   - pgbackrest-stanza-create (boot-time initialization)
    #   - WAL archiving (continuous, can't tolerate mount delays)
    fileSystems."/mnt/nas-postgresql" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/postgresql";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "hard"              # Retry indefinitely on timeout (don't fail)
        "timeo=600"         # 60-second timeout (10× default of 6s)
        "retrans=3"         # Retry 3 times before reporting error
        "_netdev"           # Wait for network before mounting
        "rw"
        "noatime"
        # REMOVED: x-systemd.automount - causes namespace issues with early services
        # REMOVED: x-systemd.idle-timeout - pgBackRest needs stable mount
        # REMOVED: "intr" - Deprecated and ignored in NFSv4
        "x-systemd.mount-timeout=30s"
      ];
    };

    fileSystems."/mnt/nas-docs" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/docs";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"  # Unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"
      ];
    };

    # MIGRATED: Legacy backup-integration system disabled in favor of unified backup system
    # modules.services.backup-integration = {
    #   enable = true;
    #   autoDiscovery.enable = true;
    #   defaultRepository = "nas-primary";
    # };

    # ACTIVE: Unified backup system integration
    # Migrated from legacy backup-integration system

    modules.services.backup = {
      enable = true;

      repositories = {
        nas-primary = {
          url = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          primary = true;
          type = "local";
        };
        r2-offsite = {
          url = "s3:https://21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
          passwordFile = config.sops.secrets."restic/password".path;
          environmentFile = config.sops.secrets."restic/r2-prod-env".path;
          primary = false;
          type = "s3";
        };
      };

      # PostgreSQL hybrid backup (pgBackRest + Restic offsite)
      postgres = {
        enable = true;
        pgbackrest.enableOffsite = true;
        pgbackrest.offsiteRepository = "r2-offsite";
      };

      # Restic backup discovery and management
      restic.enable = true;

      # ZFS snapshot coordination (opt-in for services)
      snapshots.enable = true;

      # Enterprise monitoring and verification
      monitoring.enable = true;
      verification.enable = true;
    };

    # DISABLED: Old backup module replaced by unified backup system
    # modules.backup = {
    #   enable = true;
    #
    #   # Configure ZFS snapshots for backup consistency (multi-pool support)
    #   zfs = {
#        enable = true;
#        pools = [
#          # Boot pool datasets
#          {
#            pool = "rpool";
#            datasets = [
#              "safe/home"      # User home directories
#              "safe/persist"   # System state and persistent data
#              # local/nix excluded - fully reproducible from NixOS configuration
#            ];
#          }
#          # Service data pool
#          {
#            pool = "tank";
#            datasets = [
#              "services/dispatcharr"          # dispatcharr application data
#              # Removed services/postgresql/main-wal - obsolete directory not used by pgBackRest
#            ];
#          }
#        ];
#        retention = {
#          daily = 7;
#          weekly = 4;
#          monthly = 3;
#        };
#      };
#
#      # Configure Restic backups
#      restic = {
#        enable = true;
#
#        globalSettings = {
#          compression = "auto";
#          readConcurrency = 2;
#          retention = {
#            daily = 14;
#            weekly = 8;
#            monthly = 6;
#            yearly = 2;
#          };
#        };
#
#        # Define backup repositories
#        # Note: Repository details defined inline from config.sops.secrets to avoid _module.args circular dependency
#        repositories = {
#          ${primaryRepoName} = {
#            url = primaryRepoUrl;
#            passwordFile = primaryRepoPasswordFile;
#            primary = true;
#          };
#
#          # Cloudflare R2 for offsite geographic redundancy
#          # Zero egress fees make restore testing and actual DR affordable
#          #
#          # Bucket Organization: Per-Environment Strategy
#          # - production-servers: forge, luna, nas-1 (critical infrastructure)
#          # - edge-devices: nixpi (monitoring/edge services)
#          # - workstations: rydev, rymac (development machines)
#          #
#          # Security: Each bucket has scoped API token (least privilege)
#          # - Compromised workstation cannot access server backups
#          # - Separate credentials per environment tier
#          #
#          # Security Note: Account ID in URL is NOT sensitive (identifier, not secret)
#          # - Industry standard: account IDs are public (like AWS Account IDs)
#          # - Actual secrets (API keys) are in sops: restic/r2-prod-env
#          # - Defense in depth: scoped IAM + API credentials + Restic encryption
#          r2-offsite = {
#            url = r2OffsetUrl;  # DRY: Defined once in let block
#            passwordFile = primaryRepoPasswordFile;  # Reuse same Restic encryption password
#            environmentFile = config.sops.secrets."restic/r2-prod-env".path;  # Production bucket credentials
#            primary = false;  # Secondary repository for DR
#          };
#        };
#
#        # Define backup jobs
#        jobs = {
#          system = {
#            enable = true;
#            repository = "r2-offsite";  # Send to R2 for offsite DR (NAS covered by Syncoid)
#            paths = [
#              "/home"
#              "/persist"
#              "/var/lib/backup-docs"  # Backup the documentation for DR
#            ];
#            excludePatterns = [
#              # Exclude cache directories
#              "**/.cache"
#              "**/.local/share/Trash"
#              "**/Cache"
#              "**/cache"
#              # Exclude build artifacts
#              "**/.direnv"
#              "**/result"
#              "**/target"
#              "**/node_modules"
#              # Exclude temporary files
#              "**/*.tmp"
#              "**/*.temp"
#            ];
#            tags = [ "system" "forge" "nixos" ];
#            resources = {
#              memory = "512M";
#              memoryReservation = "256M";
#              cpus = "1.0";
#            };
#          };
#
#          nix-store = {
#            enable = false;  # Optional: enable if you want to backup Nix store
#            repository = primaryRepoName;
#            paths = [ "/nix" ];
#            tags = [ "nix" "forge" ];
#            resources = {
#              memory = "1G";
#              memoryReservation = "512M";
#              cpus = "1.0";
#            };
#          };
#
#          # PostgreSQL backups now handled by pgBackRest (see default.nix)
#          # - Full backups: Daily at 2 AM to /mnt/nas-backup/pgbackrest + R2
#          # - Incremental backups: Hourly
#          # - Differential backups: Every 6 hours
#          # - WAL archiving: Continuous via archive_command
#        };
#      };
#
#      # Enable monitoring and notifications
#      monitoring = {
#        enable = true;
#
#        # Enable Prometheus metrics via Node Exporter textfile collector
#        prometheus = {
#          enable = true;
#          metricsDir = "/var/lib/node_exporter/textfile_collector";
#        };
#
#        # Error analysis
#        errorAnalysis = {
#          enable = true;
#        };
#
#        logDir = "/var/log/backup";
#      };
#
#      # Enable automated verification
#      verification = {
#        enable = true;
#        schedule = "weekly";
#        checkData = false;  # Set to true for thorough data verification (slow)
#        checkDataSubset = "10%";  # Increase subset for stronger offsite verification
#      };
#
#      # Enable restore testing
#      restoreTesting = {
#        enable = true;
#        schedule = "monthly";
#        sampleFiles = 5;
#        testDir = "/tmp/restore-tests";
#      };
#
#      # Performance settings
#      performance = {
#        cacheDir = "/var/cache/restic";
#        cacheSizeLimit = "5G";
#        ioScheduling = {
#          enable = true;
#          ioClass = "idle";
#          priority = 7;
#        };
#      };
#
#      # Enable documentation generation
#      documentation = {
#        enable = true;
#        outputDir = "/var/lib/backup-docs";
#      };
#
#      # Backup schedule
#      schedule = "daily";
#    };

    # Co-located Restic backup monitoring alerts
    # These alerts track the health of non-database backups (system state, configs, docs)
    modules.alerting.rules = lib.mkIf config.modules.services.backup.enable {
      # Backup job failed
      "restic-backup-failed" = {
        type = "promql";
        alertname = "ResticBackupFailed";
        expr = "restic_backup_status{backup_job!=\"\"} == 0";
        for = "5m";
        severity = "critical";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic backup job {{ $labels.backup_job }} failed on {{ $labels.instance }}";
          description = "Backup job {{ $labels.backup_job }} has failed. Check logs for errors. This may indicate issues with repository connectivity, authentication, or data integrity.";
          command = "journalctl -u restic-backups-{{ $labels.backup_job }}.service --since '2 hours ago'";
        };
      };

      # Backup hasn't run in expected timeframe
      # Fixed: 30-hour threshold for daily jobs (24h interval + 6h buffer)
      "restic-backup-stale" = {
        type = "promql";
        alertname = "ResticBackupStale";
        # Only consider metrics that use the backup_job label
        # 108000s = 30 hours (24h daily schedule + 6h buffer)
        expr = "(time() - restic_backup_last_success_timestamp{backup_job!=\"\"}) > 108000";
        for = "1h";
        severity = "high";
        labels = { service = "backup"; category = "restic"; group = "backups"; };
        annotations = {
          summary = "Restic backup job {{ $labels.backup_job }} never completed on {{ $labels.instance }}";
          description = "Backup job {{ $labels.backup_job }} is configured but has never successfully completed. Verify the backup configuration and check for initialization issues.";
          command = "journalctl -u restic-backups-{{ $labels.backup_job }}.service --since '24 hours ago'";
        };
      };

      # Backup duration anomaly (significantly longer than baseline)
      "restic-backup-slow" = {
        type = "promql";
        alertname = "ResticBackupSlow";
        expr = "restic_backup_duration_seconds{backup_job!=\"\"} > (avg_over_time(restic_backup_duration_seconds{backup_job!=\"\"}[7d]) * 2)";
        for = "30m";
        severity = "medium";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic backup job {{ $labels.backup_job }} is running slowly on {{ $labels.instance }}";
          description = "Backup job {{ $labels.backup_job }} is taking longer than expected ({{ $value }}s). This may indicate performance issues or large data changes.";
          command = "journalctl -u restic-backups-{{ $labels.backup_job }}.service --since '2 hours ago'";
        };
      };

      # High error count
      "restic-backup-errors" = {
        type = "promql";
        alertname = "ResticBackupErrors";
        expr = "backup_errors_by_severity_total{severity=\"critical\"} > 0";
        for = "5m";
        severity = "high";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic backup errors detected on {{ $labels.instance }}";
          description = "{{ $value }} critical backup errors. Check logs: /var/log/backup/";
        };
      };

      # Repository verification failed
      "restic-verification-failed" = {
        type = "promql";
        alertname = "ResticVerificationFailed";
        expr = "restic_verification_status == 0";
        for = "5m";
        severity = "high";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic repository verification failed for {{ $labels.repository }} on {{ $labels.hostname }}";
          description = "Repository integrity check failed. Data corruption possible. Run manual 'restic check'.";
        };
      };

      # Restore test failed
      "restic-restore-test-failed" = {
        type = "promql";
        alertname = "ResticRestoreTestFailed";
        expr = "restic_restore_test_status == 0";
        for = "5m";
        severity = "medium";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic restore test failed for {{ $labels.repository }} on {{ $labels.hostname }}";
          description = "Monthly restore test failed. Backup recoverability at risk. Investigate immediately.";
        };
      };

      # Note: ZFS pool health alert is defined in default.nix using standard node_exporter metrics
      # (zfs-pool-degraded alert removed to avoid duplication)

      # ZFS replication lag excessive
      "zfs-replication-lag-high" = {
        type = "promql";
        alertname = "ZFSReplicationLagHigh";
        expr = "zfs_replication_lag_seconds > 86400";  # 24 hours
        for = "30m";
        severity = "high";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication lag exceeds 24h: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "Dataset {{ $labels.dataset }} on {{ $labels.instance }} has not replicated to {{ $labels.target_host }} in {{ $value | humanizeDuration }}. Next steps: systemctl status syncoid-*.service; journalctl -u syncoid-*.service --since '2 hours ago'; verify SSH for user 'zfs-replication' to {{ $labels.target_host }}; check NAS reachability.";
          runbook_url = "https://prometheus.forge.holthome.net/graph?g0.expr=zfs_replication_lag_seconds&g0.tab=1";
          command = "journalctl -u syncoid-*.service --since '2 hours ago'";
        };
      };

      # ZFS replication completely stalled
      "zfs-replication-stalled" = {
        type = "promql";
        alertname = "ZFSReplicationStalled";
        expr = "zfs_replication_lag_seconds > 259200";  # 72 hours
        for = "1h";
        severity = "critical";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication stalled: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "No replication of {{ $labels.dataset }} on {{ $labels.instance }} to {{ $labels.target_host }} in {{ $value | humanizeDuration }}. Data loss risk if source fails. Investigate immediately. Check Syncoid unit logs and network/SSH to target NAS.";
          runbook_url = "https://alertmanager.forge.holthome.net";
          command = "systemctl status syncoid-*.service";
        };
      };
      # ZFS replication stale (homelab-optimized thresholds with stuck detection)
      # Alert when a previously successful replication job has not completed within the defined threshold
      "zfs-replication-stale-high" = {
        type = "promql";
        alertname = "ZFSReplicationStaleHigh";
        # 5400s = 90 minutes (6 missed 15m runs with buffer)
        # Uses changes() instead of increase() since timestamp is a gauge, not counter
        # Label filter removed - let malformed metrics fail loudly rather than silently
        expr = ''
          (
            (time() - syncoid_replication_last_success_timestamp > 5400)
            and
            (changes(syncoid_replication_last_success_timestamp[30m]) == 0)
          )
          * on (dataset, target_host) group_left (unit)
          syncoid_replication_info
        '';
        for = "15m";
        severity = "high";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication stale: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) has not succeeded in over 90 minutes and timestamp is not advancing. Check for hung syncoid processes, network issues, or remote ZFS health.";
          command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '2 hours ago'";
        };
      };

      "zfs-replication-stale-critical" = {
        type = "promql";
        alertname = "ZFSReplicationStaleCritical";
        # 14400s = 4 hours (critical threshold for homelab)
        # Uses changes() to detect stuck timestamp gauge
        # Label filter removed - let malformed metrics fail loudly rather than silently
        expr = ''
          (
            (time() - syncoid_replication_last_success_timestamp > 14400)
            and
            (changes(syncoid_replication_last_success_timestamp[30m]) == 0)
          )
          * on (dataset, target_host) group_left (unit)
          syncoid_replication_info
        '';
        for = "15m";
        severity = "critical";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication critically stale: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) has not succeeded in over 4 hours. Data loss risk is high if the source fails. Investigate immediately.";
          command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '4 hours ago'";
        };
      };

      # ZFS replication never succeeded (separate alert for newly configured jobs)
      # Alert when replication is configured but has never reported a successful run
      "zfs-replication-never-run" = {
        type = "promql";
        alertname = "ZFSReplicationNeverRun";
        # Detects when info metric exists but success timestamp doesn't
        # Grace period handled by 'for' clause to avoid noise during boot/setup
        expr = ''
          syncoid_replication_info
          unless on (dataset, target_host)
          syncoid_replication_last_success_timestamp
        '';
        for = "30m";  # 30-minute grace period for initial setup/boot
        severity = "high";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication never succeeded: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) is configured but has never reported a successful run. This condition has persisted for 30 minutes. Check SSH connectivity, permissions, and remote ZFS availability.";
          command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '1 hour ago' && ssh zfs-replication@{{ $labels.target_host }} 'zfs list'";
        };
      };

      # Syncoid systemd unit failure (accurate failure detection with target_host join)
      "syncoid-unit-failed" = {
        type = "promql";
        alertname = "SyncoidUnitFailed";
        expr = ''
          (
            node_systemd_unit_state{state="failed", name=~"syncoid-.*\\.service"} > 0
          )
          * on(name) group_left(dataset, target_host)
          (
            label_replace(syncoid_replication_info, "name", "$1", "unit", "(.+)")
            > 0
          )
        '';
        for = "10m";
        severity = "high";
        labels = { service = "storage"; category = "syncoid"; };
        annotations = {
          summary = "Syncoid unit failed: {{ $labels.dataset }} → {{ $labels.target_host }}";
          description = "The systemd unit {{ $labels.name }} is in failed state on {{ $labels.instance }}. Check logs and SSH connectivity to {{ $labels.target_host }}.";
          runbook_url = "https://prometheus.forge.holthome.net/graph?g0.expr=node_systemd_unit_state%7Bstate%3D%22failed%22%2Cname%3D~%22syncoid-.*%5C.service%22%7D&g0.tab=1";
          command = "systemctl status {{ $labels.name }} && journalctl -u {{ $labels.name }} --since '2 hours ago'";
        };
      };

      # Replication target unreachable (drives inhibition)
      "replication-target-unreachable" = {
        type = "promql";
        alertname = "ReplicationTargetUnreachable";
        expr = "syncoid_target_reachable == 0";
        for = "15m";
        severity = "high";
        labels = { service = "storage"; category = "syncoid"; };
        annotations = {
          summary = "Replication target unreachable: {{ $labels.target_host }}";
          description = "SSH probe to {{ $labels.target_host }} failed for 15m. Suppressing replication noise and investigating network/host availability.";
          command = "ssh -v zfs-replication@{{ $labels.target_host }} || ping {{ $labels.target_host }}";
        };
      };

      # Meta-alert: Info metric disappeared (CRITICAL - breaks stale detection)
      # Detects when a replication that was reporting success suddenly stops exporting its info metric
      # This would silently disable stale alerts due to the join operation failing
      # FIXED: Only alert if the systemd timer still exists (prevents false positives when replication is removed)
      "zfs-replication-info-missing" = {
        type = "promql";
        alertname = "ZFSReplicationInfoMissing";
        expr = ''
          (
            syncoid_replication_last_success_timestamp
            unless on(dataset, target_host)
            syncoid_replication_info
          )
          * on(unit) group_left()
          (
            node_systemd_unit_state{state="active", name=~"syncoid-.*\\.timer"}
            or
            node_systemd_unit_state{state="activating", name=~"syncoid-.*\\.service"}
          )
        '';
        for = "15m";
        severity = "critical";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication info metric missing for {{ $labels.dataset }}";
          description = "The syncoid_replication_info metric for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' has disappeared, but replication is still active. This will prevent stale alerts from firing. Check the metric exporter script and textfile collector.";
          command = "ls -l /var/lib/node_exporter/textfile_collector/syncoid-*.prom && systemctl status syncoid-replication-info.service";
        };
      };

      # Meta-alert: Metric exporter is stale (textfile not being updated)
      # Detects when the textfile itself hasn't been modified, indicating exporter failure
      "zfs-replication-exporter-stale" = {
        type = "promql";
        alertname = "ZFSReplicationExporterStale";
        # Check if any syncoid metrics file hasn't been updated in 30 minutes
        # Note: This assumes metrics are written to files matching pattern syncoid*.prom
        expr = ''
          time() - node_textfile_mtime_seconds{file=~"syncoid.*\\.prom"} > 1800
        '';
        for = "10m";
        severity = "medium";
        labels = { service = "storage"; category = "zfs"; };
        annotations = {
          summary = "ZFS replication metric exporter stale on {{ $labels.instance }}";
          description = "The metrics file '{{ $labels.file }}' on {{ $labels.instance }} has not been updated in over 30 minutes. Replication status is unknown. This could be a permissions issue, timer failure, or script error.";
          command = "ls -lh /var/lib/node_exporter/textfile_collector/{{ $labels.file }} && systemctl list-timers --all | grep syncoid";
        };
      };
    };
  };
}
