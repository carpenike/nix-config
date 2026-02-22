{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
in
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
    snapshotInterval = "*:0/5"; # Run snapshots every 5 minutes (for high-frequency datasets)
    replicationInterval = "*:0/15"; # Run replication every 15 minutes for faster DR

    # Retention templates for different data types
    # Services reference these via: useTemplate = [ "services" ];
    templates = {
      production = {
        hourly = 24; # 24 hours
        daily = 7; # 1 week
        weekly = 4; # 1 month
        monthly = 3; # 3 months
        autosnap = true;
        autoprune = true;
      };
      services = {
        hourly = 48; # 2 days
        daily = 14; # 2 weeks
        weekly = 8; # 2 months
        monthly = 6; # 6 months
        autosnap = true;
        autoprune = true;
      };
      # High-frequency snapshots for PostgreSQL WAL archives
      # Provides 5-minute RPO for database point-in-time recovery
      wal-frequent = {
        frequently = 12; # Keep 12 five-minute snapshots (1 hour of frequent retention)
        hourly = 48; # 2 days of hourly rollup
        daily = 7; # 1 week of daily rollup
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
          inherit (forgeDefaults.replication) targetHost sendOptions recvOptions hostKey targetName targetLocation;
          targetDataset = "backup/forge/zfs-recv/home";
        };
      };

      # System persistence - configuration and state
      "rpool/safe/persist" = {
        useTemplate = [ "production" ];
        recursive = false;
        replication = {
          inherit (forgeDefaults.replication) targetHost sendOptions recvOptions hostKey targetName targetLocation;
          targetDataset = "backup/forge/zfs-recv/persist";
        };
      };

      # Parent service dataset - metadata only, children managed by their respective modules
      # This dataset itself doesn't get snapshotted (recursive = false)
      # Individual service modules (dispatcharr, sonarr, etc.) configure their own snapshots
      # Note: No useTemplate needed - this is just a logical container, not an actual snapshot target
      "tank/services" = {
        recursive = false; # Don't snapshot children - they manage themselves
        autosnap = false; # Don't snapshot the parent directory itself
        autoprune = false;
        # No replication - individual services handle their own replication
      };

      # Observability datasets (Prometheus, Loki, Alertmanager) have been moved to their
      # respective service files (prometheus.nix, loki.nix, alertmanager.nix) following
      # the contribution pattern. This removes direct coupling from storage.nix.
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
      parentMount = "/srv"; # Fallback for services without explicit mountpoint

      services = {
        # PostgreSQL dataset is now managed by the PostgreSQL module's storage-integration.nix
        # to avoid duplicate dataset creation and configuration conflicts.
        # See: modules/nixos/services/postgresql/storage-integration.nix

        # Observability datasets (Prometheus, Loki, Alertmanager) are now managed by their
        # respective service files following the contribution pattern
        # See: hosts/forge/infrastructure/observability/{prometheus,loki,alertmanager}.nix
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
            "com.sun:auto-snapshot" = "false"; # Don't snapshot temporary clones
          };
        };
      };
    };

    # Shared NFS mount for media access from NAS
    nfsMounts.media = {
      enable = true;
      automount = false; # Disable automount for always-on media services (prevents idle timeout cascade stops)
      server = "nas.holthome.net";
      remotePath = "/mnt/tank/share";
      localPath = "/mnt/data"; # Mount point for shared NAS data (contains media/, backups/, etc.)
      group = "media";
      mode = "02775"; # setgid bit ensures new files inherit media group
      # WORKAROUND (2026-02-21): Add soft mount to prevent system freeze on NAS unreachable
      # Previous hard mount caused uninterruptible D-state cascade (full host freeze 2026-02-21)
      # With soft, NFS ops return EIO on timeout instead of blocking forever.
      # timeo=150 = 15 seconds (in deciseconds), retrans=3 = 3 retries before EIO.
      mountOptions = [ "nfsvers=4.2" "soft" "timeo=150" "retrans=3" "rw" "noatime" ];
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
      labels = { category = "storage"; service = "zfs"; };
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
      labels = { category = "storage"; service = "zfs"; };
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
      expr = "zfs_replication_lag_seconds > 86400"; # 24 hours
      for = "30m";
      severity = "high";
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication lag exceeds 24h: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "Dataset {{ $labels.dataset }} on {{ $labels.instance }} has not replicated to {{ $labels.target_host }} in {{ $value | humanizeDuration }}. Next steps: systemctl status syncoid-*.service; journalctl -u syncoid-*.service --since '2 hours ago'; verify SSH for user 'zfs-replication' to {{ $labels.target_host }}; check NAS reachability.";
        runbook_url = "https://prom.holthome.net/graph?g0.expr=zfs_replication_lag_seconds&g0.tab=1";
        command = "journalctl -u syncoid-*.service --since '2 hours ago'";
      };
    };

    # ZFS replication completely stalled
    "zfs-replication-stalled" = {
      type = "promql";
      alertname = "ZFSReplicationStalled";
      expr = "zfs_replication_lag_seconds > 259200"; # 72 hours
      for = "1h";
      severity = "critical";
      labels = { service = "syncoid"; category = "replication"; };
      annotations = {
        summary = "ZFS replication stalled: {{ $labels.dataset }} → {{ $labels.target_host }}";
        description = "No replication of {{ $labels.dataset }} on {{ $labels.instance }} to {{ $labels.target_host }} in {{ $value | humanizeDuration }}. Data loss risk if source fails. Investigate immediately. Check Syncoid unit logs and network/SSH to target NAS.";
        runbook_url = "https://am.holthome.net";
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
        runbook_url = "https://prom.holthome.net/graph?g0.expr=node_systemd_unit_state%7Bstate%3D%22failed%22%2Cname%3D~%22syncoid-.*%5C.service%22%7D&g0.tab=1";
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

    # ZFS Pool Health Monitoring
    # Co-located with ZFS lifecycle management following co-location principle
    "zfs-pool-unhealthy" = {
      type = "promql";
      alertname = "ZfsPoolUnhealthy";
      expr = "zfs_pool_health{pool!=\"\"} > 0";
      for = "5m";
      severity = "critical";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} is unhealthy";
        description = "Pool {{ $labels.pool }} has status {{ $labels.health }}. Run 'zpool status {{ $labels.pool }}' to investigate.";
        command = "zpool status {{ $labels.pool }}";
      };
    };

    "zfs-capacity-critical" = {
      type = "promql";
      alertname = "ZfsPoolCapacityCritical";
      expr = "zfs_pool_capacity_percent{pool!=\"\"} > 95";
      for = "5m";
      severity = "critical";
      labels = { service = "zfs"; category = "capacity"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} critically full";
        description = "Pool {{ $labels.pool }} is {{ $value }}% full. Immediate cleanup required to prevent write failures.";
        command = "zpool list {{ $labels.pool }} && df -h";
      };
    };

    "zfs-capacity-warning" = {
      type = "promql";
      alertname = "ZfsPoolCapacityHigh";
      expr = "zfs_pool_capacity_percent{pool!=\"\"} > 85";
      for = "15m";
      severity = "high";
      labels = { service = "zfs"; category = "capacity"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} reaching capacity";
        description = "Pool {{ $labels.pool }} is {{ $value }}% full. Plan cleanup or expansion.";
        command = "zpool list {{ $labels.pool }}";
      };
    };

    "zfs-fragmentation-high" = {
      type = "promql";
      alertname = "ZfsPoolFragmentationHigh";
      expr = "zfs_pool_fragmentation_percent{pool!=\"\"} > 50";
      for = "30m";
      severity = "medium";
      labels = { service = "zfs"; category = "performance"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} highly fragmented";
        description = "Pool {{ $labels.pool }} is {{ $value }}% fragmented. May impact performance.";
        command = "zpool list -v {{ $labels.pool }}";
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

  # ZFS snapshot metrics exporter
  # Collects snapshot count, age, and space usage for all datasets with backup policies
  # Moved from pgbackrest.nix for proper co-location (monitors ZFS lifecycle, not pgBackRest)
  systemd.services.zfs-snapshot-metrics =
    let
      # Dynamically generate dataset list from backup.zfs.pools configuration
      # This ensures metrics stay in sync with backup configuration
      allDatasets = lib.flatten (
        map
          (pool:
            map (dataset: "${pool.pool}/${dataset}") pool.datasets
          )
          config.modules.backup.zfs.pools
      );
      # Convert to bash array format
      datasetsArray = lib.concatMapStrings (ds: ''"${ds}" '') allDatasets;
    in
    {
      description = "Export ZFS snapshot metrics for all backup datasets";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = ''
                set -euo pipefail

                METRICS_FILE="/var/lib/node_exporter/textfile_collector/zfs_snapshots.prom"
                METRICS_TEMP="$METRICS_FILE.tmp"

                # Start metrics file
                cat > "$METRICS_TEMP" <<'HEADER'
        # HELP zfs_snapshot_count Number of snapshots per dataset
        # TYPE zfs_snapshot_count gauge
        HEADER

                # Datasets to monitor (dynamically generated from backup.nix)
                DATASETS=(${datasetsArray})

                # Count snapshots per dataset
                for dataset in "''${DATASETS[@]}"; do
                  SNAPSHOT_COUNT=$(${lib.getExe config.boot.zfs.package} list -H -t snapshot -o name | ${lib.getExe' pkgs.gnugrep "grep"} -c "^$dataset@" || echo 0)
                  echo "zfs_snapshot_count{dataset=\"$dataset\"} $SNAPSHOT_COUNT" >> "$METRICS_TEMP"
                done

                # Add latest snapshot age metrics (using locale-safe Unix timestamps)
                cat >> "$METRICS_TEMP" <<'HEADER2'

        # HELP zfs_snapshot_latest_timestamp Creation time of most recent snapshot per dataset (Unix timestamp)
        # TYPE zfs_snapshot_latest_timestamp gauge
        HEADER2

                for dataset in "''${DATASETS[@]}"; do
                  # Get most recent snapshot name
                  LATEST_SNAPSHOT=$(${lib.getExe config.boot.zfs.package} list -H -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n 1 || echo "")
                  if [ -n "$LATEST_SNAPSHOT" ]; then
                    # Get creation time as Unix timestamp (locale-safe, uses -p for parseable output)
                    LATEST_TIMESTAMP=$(${lib.getExe config.boot.zfs.package} get -H -p -o value creation "$LATEST_SNAPSHOT" 2>/dev/null || echo 0)
                    echo "zfs_snapshot_latest_timestamp{dataset=\"$dataset\"} $LATEST_TIMESTAMP" >> "$METRICS_TEMP"
                  fi
                done

                # Add total space used by all snapshots per dataset
                cat >> "$METRICS_TEMP" <<'HEADER3'

        # HELP zfs_snapshot_total_used_bytes Total space used by all snapshots for a dataset
        # TYPE zfs_snapshot_total_used_bytes gauge
        HEADER3

                for dataset in "''${DATASETS[@]}"; do
                  TOTAL_USED=$(${lib.getExe config.boot.zfs.package} list -Hp -t snapshot -o used -r "$dataset" 2>/dev/null | ${lib.getExe' pkgs.gawk "awk"} '{sum+=$1} END {print sum}' || echo 0)
                  echo "zfs_snapshot_total_used_bytes{dataset=\"$dataset\"} $TOTAL_USED" >> "$METRICS_TEMP"
                done

                mv "$METRICS_TEMP" "$METRICS_FILE"
      '';
      after = [ "zfs-mount.service" ];
      wants = [ "zfs-mount.service" ];
    };

  systemd.timers.zfs-snapshot-metrics = {
    description = "Collect ZFS snapshot metrics every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Run 1 minute after snapshots (avoids race condition with pg-zfs-snapshot)
      OnCalendar = "*:1/5";
      Persistent = true;
    };
  };

  # =============================================================================
  # Post-Replication Property Fixup for nas-1
  # =============================================================================
  #
  # After syncoid replicates datasets to nas-1, child datasets inherit canmount=on
  # and mountpoint properties from forge. This causes zfs-mount.service failures
  # on nas-1 because it tries to mount datasets at /var/lib/* paths that don't exist.
  #
  # This service SSHs to nas-1 immediately after syncoid completes and sets
  # canmount=noauto on any replicated datasets that have canmount=on.
  #
  # This is better than a daily timer because:
  # - No vulnerability window where reboot could trigger unwanted mounts
  # - Property fixup happens atomically with replication
  # - Immediate feedback on replication success
  #
  # Reference: https://github.com/jimsalterjrs/sanoid/issues/972

  systemd.services.syncoid-post-fixup-nas1 = {
    description = "Fix canmount properties on nas-1 after ZFS replication";
    # Run after the syncoid target completes (all replication jobs)
    after = [ "syncoid.target" ];
    wantedBy = [ "syncoid.target" ];
    # Only run if SSH key exists
    unitConfig.ConditionPathExists = [ (toString config.sops.secrets."zfs-replication/ssh-key".path) ];

    serviceConfig = {
      Type = "oneshot";
      User = "zfs-replication";
      Group = "zfs-replication";
      # Use the same SSH key as syncoid
      Environment = "SSH_AUTH_SOCK=";
    };

    script = ''
      set -euo pipefail

      SSH_KEY="${config.sops.secrets."zfs-replication/ssh-key".path}"
      TARGET_HOST="nas-1.holthome.net"
      TARGET_USER="zfs-replication"

      # Define parent datasets to process
      PARENTS="backup/forge/zfs-recv backup/forge/services"

      echo "[$(date -Iseconds)] Running post-replication canmount fixup on $TARGET_HOST"

      # SSH to nas-1 and fix canmount properties
      ${pkgs.openssh}/bin/ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        -o ConnectTimeout=30 \
        "$TARGET_USER@$TARGET_HOST" << 'EOF'
      set -euo pipefail

      ZFS="/run/current-system/sw/bin/zfs"
      FIXED=0

      for parent in backup/forge/zfs-recv backup/forge/services; do
        if $ZFS list "$parent" >/dev/null 2>&1; then
          # Process all child datasets (skip the parent itself with tail -n +2)
          for ds in $($ZFS list -H -o name -t filesystem -r "$parent" | tail -n +2); do
            current=$($ZFS get -H -o value canmount "$ds")
            if [ "$current" = "on" ]; then
              echo "Setting canmount=noauto on $ds"
              $ZFS set canmount=noauto "$ds"
              FIXED=$((FIXED + 1))
            fi
          done
        fi
      done

      echo "Fixed canmount on $FIXED dataset(s)"
      EOF

      echo "[$(date -Iseconds)] Post-replication fixup complete"
    '';
  };
}
