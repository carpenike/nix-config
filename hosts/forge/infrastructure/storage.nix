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

    # ZFS Replication Monitoring (Syncoid)
    # Co-located with replication configuration (modules.backup.sanoid.datasets.*.replication)
    # following the cohesion principle

    # ZFS replication lag excessive
    "zfs-replication-lag-high" = {
      type = "promql";
      alertname = "ZFSReplicationLagHigh";
      expr = "zfs_replication_lag_seconds > 86400";  # 24 hours
      for = "30m";
      severity = "high";
      labels = { service = "syncoid"; category = "replication"; };
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
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication stalled: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "No replication of {{ $labels.dataset }} on {{ $labels.instance }} to {{ $labels.target_host }} in {{ $value | humanizeDuration }}. Data loss risk if source fails. Investigate immediately. Check Syncoid unit logs and network/SSH to target NAS.";
        runbook_url = "https://alertmanager.forge.holthome.net";
        command = "systemctl status syncoid-*.service";
      };
    };

    # ZFS replication stale (homelab-optimized thresholds with stuck detection)
    "zfs-replication-stale-high" = {
      type = "promql";
      alertname = "ZFSReplicationStaleHigh";
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
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication stale: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) has not succeeded in over 90 minutes and timestamp is not advancing. Check for hung syncoid processes, network issues, or remote ZFS health.";
        command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '2 hours ago'";
      };
    };

    "zfs-replication-stale-critical" = {
      type = "promql";
      alertname = "ZFSReplicationStaleCritical";
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
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication critically stale: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) has not succeeded in over 4 hours. Data loss risk is high if the source fails. Investigate immediately.";
        command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '4 hours ago'";
      };
    };

    # ZFS replication never succeeded
    "zfs-replication-never-run" = {
      type = "promql";
      alertname = "ZFSReplicationNeverRun";
      expr = ''
        syncoid_replication_info
        unless on (dataset, target_host)
        syncoid_replication_last_success_timestamp
      '';
      for = "30m";
      severity = "high";
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication never succeeded: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "Replication for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' (unit: {{ $labels.unit }}) is configured but has never reported a successful run. This condition has persisted for 30 minutes. Check SSH connectivity, permissions, and remote ZFS availability.";
        command = "systemctl status {{ $labels.unit }} && journalctl -u {{ $labels.unit }} --since '1 hour ago' && ssh zfs-replication@{{ $labels.target_host }} 'zfs list'";
      };
    };

    # Syncoid systemd unit failure
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
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "Syncoid unit failed: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "The systemd unit {{ $labels.name }} is in failed state on {{ $labels.instance }}. Check logs and SSH connectivity to {{ $labels.target_host }}.";
        runbook_url = "https://prometheus.forge.holthome.net/graph?g0.expr=node_systemd_unit_state%7Bstate%3D%22failed%22%2Cname%3D~%22syncoid-.*%5C.service%22%7D&g0.tab=1";
        command = "systemctl status {{ $labels.name }} && journalctl -u {{ $labels.name }} --since '2 hours ago'";
      };
    };

    # Replication target unreachable
    "replication-target-unreachable" = {
      type = "promql";
      alertname = "ReplicationTargetUnreachable";
      expr = "syncoid_target_reachable == 0";
      for = "15m";
      severity = "high";
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "Replication target unreachable: {{ $labels.target_host }}";
        description = "SSH probe to {{ $labels.target_host }} failed for 15m. Suppressing replication noise and investigating network/host availability.";
        command = "ssh -v zfs-replication@{{ $labels.target_host }} || ping {{ $labels.target_host }}";
      };
    };

    # Meta-alert: Info metric disappeared
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
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication info metric missing for {{ $labels.dataset }}";
        description = "The syncoid_replication_info metric for dataset '{{ $labels.dataset }}' to '{{ $labels.target_host }}' has disappeared, but replication is still active. This will prevent stale alerts from firing. Check the metric exporter script and textfile collector.";
        command = "ls -l /var/lib/node_exporter/textfile_collector/syncoid-*.prom && systemctl status syncoid-replication-info.service";
      };
    };

    # Meta-alert: Metric exporter is stale
    "zfs-replication-exporter-stale" = {
      type = "promql";
      alertname = "ZFSReplicationExporterStale";
      expr = ''
        time() - node_textfile_mtime_seconds{file=~"syncoid.*\\.prom"} > 1800
      '';
      for = "10m";
      severity = "medium";
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication metric exporter stale on {{ $labels.instance }}";
        description = "The metrics file '{{ $labels.file }}' on {{ $labels.instance }} has not been updated in over 30 minutes. Replication status is unknown. This could be a permissions issue, timer failure, or script error.";
        command = "ls -lh /var/lib/node_exporter/textfile_collector/{{ $labels.file }} && systemctl list-timers --all | grep syncoid";
      };
    };
  };
}
