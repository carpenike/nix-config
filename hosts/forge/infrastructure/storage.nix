{ config, lib, ... }:

{
  # System-level ZFS storage management
  # This file contains:
  # - Sanoid templates (reusable snapshot/retention policies)
  # - System-level datasets (home, persist)
  # - PostgreSQL-specific datasets (controlled by postgresql service)
  # - Parent container dataset (tank/services)
  # - ZFS monitoring alerts (co-located with storage configuration)
  #
  # Service-specific datasets are configured in their respective service files
  # following the contribution pattern (e.g., services/sonarr.nix configures tank/services/sonarr)

  modules.backup.sanoid = {
    enable = true;
    sshKeyPath = config.sops.secrets."zfs-replication/ssh-key".path;
    snapshotInterval = "*:0/5";  # Run snapshots every 5 minutes (for high-frequency datasets)
    replicationInterval = "*:0/15";  # Run replication every 15 minutes for faster DR

    # Retention templates for different data types
    # Services reference these via: useTemplate = [ "services" ];
    templates = {
      production = {
        hourly = 24;      # 24 hours
        daily = 7;        # 1 week
        weekly = 4;       # 1 month
        monthly = 3;      # 3 months
        autosnap = true;
        autoprune = true;
      };
      services = {
        hourly = 48;      # 2 days
        daily = 14;       # 2 weeks
        weekly = 8;       # 2 months
        monthly = 6;      # 6 months
        autosnap = true;
        autoprune = true;
      };
      # High-frequency snapshots for PostgreSQL WAL archives
      # Provides 5-minute RPO for database point-in-time recovery
      wal-frequent = {
        frequently = 12;  # Keep 12 five-minute snapshots (1 hour of frequent retention)
        hourly = 48;      # 2 days of hourly rollup
        daily = 7;        # 1 week of daily rollup
        autosnap = true;
        autoprune = true;
      };
    };

    # System-level dataset configuration
    datasets = {
      # Home directory - user data
      "rpool/safe/home" = {
        useTemplate = [ "production" ];
        recursive = false;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/home";
          sendOptions = "w";  # Raw encrypted send
          recvOptions = "u";  # Don't mount on receive
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # System persistence - configuration and state
      "rpool/safe/persist" = {
        useTemplate = [ "production" ];
        recursive = false;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/persist";
          sendOptions = "w";
          recvOptions = "u";
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # Parent service dataset - metadata only, children managed by their respective modules
      # This dataset itself doesn't get snapshotted (recursive = false)
      # Individual service modules (dispatcharr, sonarr, etc.) configure their own snapshots
      # Note: No useTemplate needed - this is just a logical container, not an actual snapshot target
      "tank/services" = {
        recursive = false;  # Don't snapshot children - they manage themselves
        autosnap = false;   # Don't snapshot the parent directory itself
        autoprune = false;
        # No replication - individual services handle their own replication
      };

      # PostgreSQL-specific datasets
      # Explicitly disable snapshots on PostgreSQL dataset (rely on pgBackRest)
      "tank/services/postgresql" = {
        autosnap = false;
        autoprune = false;
        recursive = false;
      };

      # Explicitly disable snapshots/replication on Prometheus dataset (metrics are disposable)
      # Rationale (multi-model consensus 8.7/10 confidence):
      # - Industry best practice: Don't backup Prometheus TSDB, only configs/dashboards
      # - 15-day metric retention doesn't justify 6-month snapshot policy
      # - CoW amplification during TSDB compaction degrades performance
      # - Losing metrics on rebuild is acceptable; alerting/monitoring continues immediately
      "tank/services/prometheus" = {
        autosnap = false;
        autoprune = false;
        recursive = false;
      };
    };
  };

  # ZFS dataset creation and configuration
  # forge uses the tank pool (2x NVME) for service data
  # tank/services acts as a logical parent (not mounted)
  # Individual services mount to standard FHS paths
  modules.storage = {
    datasets = {
      enable = true;
      parentDataset = "tank/services";
      parentMount = "/srv";  # Fallback for services without explicit mountpoint

      services = {
        # PostgreSQL dataset is now managed by the PostgreSQL module's storage-integration.nix
        # to avoid duplicate dataset creation and configuration conflicts.
        # See: hosts/_modules/nixos/services/postgresql/storage-integration.nix

        # Prometheus time-series database
        # Multi-model consensus (GPT-5 + Gemini 2.5 Pro + Gemini 2.5 Flash): 8.7/10 confidence
        # Verdict: Prometheus TSDB is correct tool; ZFS snapshots are excessive for disposable metrics
        prometheus = {
          recordsize = "128K";  # Aligned with Prometheus WAL segments and 2h block files
          compression = "lz4";  # Minimal overhead; TSDB chunks already compressed
          mountpoint = "/var/lib/prometheus2";
          owner = "prometheus";
          group = "prometheus";
          mode = "0755";
          properties = {
            # Industry best practice: Do NOT snapshot Prometheus TSDB (metrics are disposable)
            # Reasoning: 15-day retention doesn't justify 6-month snapshots; configs in Git, data replaceable
            # CoW amplification during TSDB compaction significantly impacts performance under snapshots
            "com.sun:auto-snapshot" = "false";  # Disable snapshots (was: true)
            logbias = "throughput";  # Optimize for streaming writes, not low-latency sync
            primarycache = "metadata";  # Avoid ARC pollution; Prometheus has its own caching
            atime = "off";  # Reduce metadata writes on read-heavy query workloads
          };
        };

        # Loki log aggregation storage
        # Optimized for log chunks and WAL files with appropriate compression
        loki = {
          recordsize = "1M";      # Optimized for log chunks (large sequential writes)
          compression = "zstd";   # Better compression for text logs than lz4
          mountpoint = "/var/lib/loki";
          owner = "loki";
          group = "loki";
          mode = "0750";
          properties = {
            "com.sun:auto-snapshot" = "true";   # Enable snapshots for log retention
            logbias = "throughput";             # Optimize for streaming log writes
            atime = "off";                      # Reduce metadata overhead
            primarycache = "metadata";          # Don't cache log data in ARC
          };
        };

        # Alertmanager: Using ephemeral root filesystem storage
        # Rationale (GPT-5 validated):
        # - Only stores silences and notification deduplication state
        # - Homelab acceptable to lose silences on restart
        # - Duplicate notifications after restart are tolerable
        # - Dedicated dataset unnecessary for minimal administrative state
        # Location: /var/lib/alertmanager on rpool/local/root (not snapshotted)
        #
        # Updated: Manage Alertmanager storage via ZFS storage module for consistency
        # (still not snapshotted; data is non-critical). This creates the mountpoint
        # with correct ownership/permissions and ensures ordering via zfs-service-datasets.
        alertmanager = {
          recordsize = "16K";     # Small files; minimal overhead
          compression = "lz4";    # Fast, default
          mountpoint = "/var/lib/alertmanager";
          owner = "alertmanager";
          group = "alertmanager";
          mode = "0750";
          properties = {
            "com.sun:auto-snapshot" = "false";  # Do not snapshot (non-critical state)
            logbias = "throughput";
            primarycache = "metadata";
            atime = "off";
          };
        };
      };

      # Utility datasets (not under parentDataset/services)
      utility = {
        # Temporary dataset for ZFS clone-based backups
        # Used by snapshot-based backup services (dispatcharr, plex)
        # to avoid .zfs directory issues when backing up mounted filesystems
        "tank/temp" = {
          mountpoint = "none";
          compression = "lz4";
          recordsize = "128K";
          properties = {
            "com.sun:auto-snapshot" = "false";  # Don't snapshot temporary clones
          };
        };
      };
    };

    # Shared NFS mount for media access from NAS
    nfsMounts.media = {
      enable = true;
      automount = false;  # Disable automount for always-on media services (prevents idle timeout cascade stops)
      server = "nas.holthome.net";
      remotePath = "/mnt/tank/share";
      localPath = "/mnt/data";  # Mount point for shared NAS data (contains media/, backups/, etc.)
      group = "media";
      mode = "02775";  # setgid bit ensures new files inherit media group
      mountOptions = [ "nfsvers=4.2" "timeo=60" "retry=5" "rw" "noatime" ];
    };
  };

  # ZFS monitoring alerts (co-located with storage configuration following contribution pattern)
  modules.alerting.rules = lib.mkIf config.modules.filesystems.zfs.enable {
    # ZFS pool health degraded
    "zfs-pool-degraded" = {
      type = "promql";
      alertname = "ZFSPoolDegraded";
      expr = "node_zfs_zpool_state{state!=\"online\",zpool!=\"\"} > 0";
      for = "5m";
      severity = "critical";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.zpool }} is degraded on {{ $labels.instance }}";
        description = "Pool state: {{ $labels.state }}. Check 'zpool status {{ $labels.zpool }}' for details.";
        command = "zpool status {{ $labels.zpool }}";
      };
    };

    # ZFS snapshot age violations
    "zfs-snapshot-stale" = {
      type = "promql";
      alertname = "ZFSSnapshotStale";
      expr = "(time() - zfs_snapshot_latest_timestamp{dataset!=\"\"}) > 3600";
      for = "30m";
      severity = "high";
      labels = { service = "zfs"; category = "backup"; };
      annotations = {
        summary = "ZFS snapshots are stale for {{ $labels.dataset }} on {{ $labels.instance }}";
        description = "Last snapshot was {{ $value | humanizeDuration }} ago. Check sanoid service.";
        command = "systemctl status sanoid.service && journalctl -u sanoid.service --since '2 hours ago'";
      };
    };

    # ZFS snapshot count too low
    "zfs-snapshot-count-low" = {
      type = "promql";
      alertname = "ZFSSnapshotCountLow";
      expr = "zfs_snapshot_count{dataset!=\"\"} < 2";
      for = "1h";
      severity = "high";
      labels = { service = "zfs"; category = "backup"; };
      annotations = {
        summary = "ZFS snapshot count is low for {{ $labels.dataset }} on {{ $labels.instance }}";
        description = "Only {{ $value }} snapshots exist. Sanoid autosnap may be failing.";
        command = "zfs list -t snapshot | grep {{ $labels.dataset }}";
      };
    };

    # ZFS pool space usage high
    "zfs-pool-space-high" = {
      type = "promql";
      alertname = "ZFSPoolSpaceHigh";
      expr = "(node_zfs_zpool_used_bytes{zpool!=\"\"} / node_zfs_zpool_size_bytes) > 0.80";
      for = "15m";
      severity = "high";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.zpool }} is {{ $value | humanizePercentage }} full on {{ $labels.instance }}";
        description = "Pool usage exceeds 80%. Consider expanding pool or cleaning up data.";
        command = "zpool list {{ $labels.zpool }} && zfs list -o space";
      };
    };

    # ZFS pool space critical
    "zfs-pool-space-critical" = {
      type = "promql";
      alertname = "ZFSPoolSpaceCritical";
      expr = "(node_zfs_zpool_used_bytes{zpool!=\"\"} / node_zfs_zpool_size_bytes) > 0.90";
      for = "5m";
      severity = "critical";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.zpool }} is {{ $value | humanizePercentage }} full on {{ $labels.instance }}";
        description = "CRITICAL: Pool usage exceeds 90%. Immediate action required to prevent write failures.";
        command = "zpool list {{ $labels.zpool }} && df -h";
      };
    };

    # ZFS preseed restore failed
    "zfs-preseed-failed" = {
      type = "promql";
      alertname = "ZFSPreseedFailed";
      expr = "zfs_preseed_status == 0 and changes(zfs_preseed_last_completion_timestamp_seconds[15m]) > 0";
      for = "0m";
      severity = "critical";
      labels = { service = "zfs-preseed"; category = "disaster-recovery"; };
      annotations = {
        summary = "ZFS pre-seed restore failed for {{ $labels.service }}";
        description = "The automated restore for service '{{ $labels.service }}' using method '{{ $labels.method }}' has failed. The service will start with an empty data directory. Manual intervention is required. Check logs with: journalctl -u preseed-{{ $labels.service }}.service";
      };
    };

    # ZFS preseed aborted due to unhealthy pool
    "zfs-preseed-pool-unhealthy" = {
      type = "promql";
      alertname = "ZFSPreseedPoolUnhealthy";
      expr = ''
        zfs_preseed_status{method="pool_unhealthy"} == 0
        and
        changes(zfs_preseed_last_completion_timestamp_seconds{method="pool_unhealthy"}[15m]) > 0
      '';
      for = "0m";
      severity = "critical";
      labels = { service = "zfs-preseed"; category = "storage"; };
      annotations = {
        summary = "ZFS pre-seed for {{ $labels.service }} aborted due to unhealthy pool";
        description = "The pre-seed restore for '{{ $labels.service }}' was aborted because its parent ZFS pool is not in an ONLINE state. Check 'zpool status' for details.";
        command = "zpool status";
      };
    };

    # ZFS Snapshot Age Monitoring (24hr threshold)
    zfs-snapshot-too-old = {
      alertname = "zfs-snapshot-too-old";
      expr = ''
        zfs_latest_snapshot_age_seconds > 86400
      '';
      for = "30m";
      severity = "high";
      labels = { category = "storage"; };
      annotations = {
        summary = "ZFS snapshot on {{ $labels.hostname }}:{{ $labels.name }} is older than 24 hours";
        description = "The latest snapshot for dataset '{{ $labels.name }}' on '{{ $labels.hostname }}' is {{ $value | humanizeDuration }} old. Expected daily snapshots.";
        command = "zfs list -t snapshot -o name,creation -s creation {{ $labels.name }}";
      };
    };

    # ZFS Snapshot Age Critical (48hr threshold)
    zfs-snapshot-critical = {
      alertname = "zfs-snapshot-critical";
      expr = ''
        zfs_latest_snapshot_age_seconds > 172800
      '';
      for = "1h";
      severity = "critical";
      labels = { category = "storage"; };
      annotations = {
        summary = "ZFS snapshot on {{ $labels.hostname }}:{{ $labels.name }} is critically old (>48 hours)";
        description = "The latest snapshot for dataset '{{ $labels.name }}' on '{{ $labels.hostname }}' is {{ $value | humanizeDuration }} old. Backup system may be failing.";
        command = "zfs list -t snapshot -o name,creation -s creation {{ $labels.name }}";
      };
    };

    # ZFS Holds Stale Detection (Restic cleanup monitoring)
    zfs-holds-stale = {
      alertname = "zfs-holds-stale";
      expr = ''
        count(zfs_hold_age_seconds > 21600) by (hostname) > 3
      '';
      for = "2h";
      severity = "medium";
      labels = { category = "storage"; };
      annotations = {
        summary = "Stale ZFS holds detected on {{ $labels.hostname }}";
        description = "More than 3 ZFS holds on '{{ $labels.hostname }}' are older than 6 hours. This may indicate Restic backup cleanup issues.";
        command = "zfs holds -H | awk '{print $1, $2}' | sort";
      };
    };
  };
}
