{ lib, config, ... }:

{
  # Infrastructure-level monitoring alerts for forge
  # This file contains system and infrastructure alert rules:
  # - ZFS pool health and snapshot monitoring
  # - System resource alerts (CPU, memory, disk, systemd)
  # - Container health monitoring
  # - Backup and replication monitoring
  #
  # Service-specific alerts are co-located with their services following the contribution pattern

  modules.alerting = {
    # Enable dead man's switch via Healthchecks.io
    receivers.healthchecks.urlSecret = "monitoring/healthchecks-url";

    # Using lib.mkMerge to combine multiple alert rule sets
    rules = lib.mkMerge [
      # ZFS monitoring alerts (conditional on ZFS being enabled)
      (lib.mkIf config.modules.filesystems.zfs.enable {
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
      })  # End ZFS alerts mkIf

      # System health monitoring alerts (always enabled)
      {
        # Node exporter down
        "node-exporter-down" = {
          type = "promql";
          alertname = "NodeExporterDown";
          expr = "up{job=\"node\"} == 0";
          for = "2m";
          severity = "critical";
          labels = { service = "system"; category = "monitoring"; };
          annotations = {
            summary = "Node exporter is down on {{ $labels.instance }}";
            description = "Cannot collect system metrics. Check prometheus-node-exporter.service status.";
          };
        };

        # Observability service alerts (prometheus-down, alertmanager-down) are now
        # co-located with their respective service files following the contribution pattern

        # Dead Man's Switch / Watchdog
        # This alert always fires to test the entire monitoring pipeline
        # It's routed to an external service (healthchecks.io) to detect total system failure
        "watchdog" = {
          type = "promql";
          alertname = "Watchdog";
          expr = "vector(1)";
          # No 'for' needed - should always be firing
          severity = "critical";
          labels = { service = "monitoring"; category = "meta"; };
          annotations = {
            summary = "Watchdog alert for monitoring pipeline";
            description = "This alert is always firing to test the entire monitoring pipeline. It should be routed to an external dead man's switch service.";
          };
        };

        # Disk space critical
        "filesystem-space-critical" = {
          type = "promql";
          alertname = "FilesystemSpaceCritical";
          expr = ''
            (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) < 0.10
          '';
          for = "5m";
          severity = "critical";
          labels = { service = "system"; category = "storage"; };
          annotations = {
            summary = "Filesystem {{ $labels.mountpoint }} is critically low on space on {{ $labels.instance }}";
            description = "Only {{ $value | humanizePercentage }} available. Immediate cleanup required.";
          };
        };

        # Disk space warning
        "filesystem-space-low" = {
          type = "promql";
          alertname = "FilesystemSpaceLow";
          expr = ''
            (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) < 0.20
          '';
          for = "15m";
          severity = "high";
          labels = { service = "system"; category = "storage"; };
          annotations = {
            summary = "Filesystem {{ $labels.mountpoint }} is low on space on {{ $labels.instance }}";
            description = "Only {{ $value | humanizePercentage }} available. Plan cleanup or expansion.";
          };
        };

        # High CPU load
        "high-cpu-load" = {
          type = "promql";
          alertname = "HighCPULoad";
          expr = "node_load15 > (count(node_cpu_seconds_total{mode=\"idle\"}) * 0.8)";
          for = "15m";
          severity = "medium";
          labels = { service = "system"; category = "performance"; };
          annotations = {
            summary = "High CPU load on {{ $labels.instance }}";
            description = "15-minute load average is {{ $value }}. Investigate resource-intensive processes.";
          };
        };

        # High memory usage
        "high-memory-usage" = {
          type = "promql";
          alertname = "HighMemoryUsage";
          expr = ''
            (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.90
          '';
          for = "10m";
          severity = "high";
          labels = { service = "system"; category = "performance"; };
          annotations = {
            summary = "High memory usage on {{ $labels.instance }}";
            description = "Memory usage is {{ $value | humanizePercentage }}. Risk of OOM kills.";
          };
        };

        # SystemD unit failed
        "systemd-unit-failed" = {
          type = "promql";
          alertname = "SystemdUnitFailed";
          expr = ''
            node_systemd_unit_state{state="failed"} == 1
          '';
          for = "5m";
          severity = "high";
          labels = { service = "system"; category = "systemd"; };
          annotations = {
            summary = "SystemD unit {{ $labels.name }} failed on {{ $labels.instance }}";
            description = "Service is in failed state. Check: systemctl status {{ $labels.name }}";
          };
        };

        # Service-specific alerts (dispatcharr, sonarr, qbittorrent, sabnzbd) are now
        # co-located with their respective service files following the contribution pattern

        # Container health check failures
        "container-health-check-failed" = {
          type = "promql";
          alertname = "ContainerHealthCheckFailed";
          expr = ''
            container_health_status{health!="healthy"} == 1
          '';
          for = "5m";
          severity = "medium";
          labels = { service = "container"; category = "health"; };
          annotations = {
            summary = "Container {{ $labels.name }} health check failed on {{ $labels.instance }}";
            description = "Container health status is {{ $labels.health }}. Check container logs: podman logs {{ $labels.name }}";
            command = "podman logs {{ $labels.name }} --since 30m";
          };
        };

        # High container memory usage
        "container-memory-high" = {
          type = "promql";
          alertname = "ContainerMemoryHigh";
          expr = ''
            container_memory_percent > 85
          '';
          for = "10m";
          severity = "medium";
          labels = { service = "container"; category = "performance"; };
          annotations = {
            summary = "Container {{ $labels.name }} memory usage is high on {{ $labels.instance }}";
            description = "Memory usage is {{ $value }}%. Monitor for potential OOM issues.";
            command = "podman stats {{ $labels.name }} --no-stream";
          };
        };

        # Backup and ZFS snapshot health alerts (Gemini Pro recommendations)

        # ZFS snapshot age too old - Sanoid not running
        "zfs-snapshot-too-old" = {
          type = "promql";
          alertname = "ZFSSnapshotTooOld";
          expr = ''
            zfs_latest_snapshot_age_seconds > 86400
          '';
          for = "30m";
          severity = "high";
          labels = { service = "backup"; category = "zfs"; };
          annotations = {
            summary = "ZFS snapshot for {{ $labels.dataset }} is over 24 hours old on {{ $labels.hostname }}";
            description = "Latest snapshot age: {{ $value | humanizeDuration }}. Sanoid may not be running. Check: systemctl status sanoid.service";
            command = "systemctl status sanoid.service && journalctl -u sanoid.service --since '24h'";
          };
        };

        # ZFS snapshot critically old - backup data at risk
        "zfs-snapshot-critical" = {
          type = "promql";
          alertname = "ZFSSnapshotCritical";
          expr = ''
            zfs_latest_snapshot_age_seconds > 172800
          '';
          for = "1h";
          severity = "critical";
          labels = { service = "backup"; category = "zfs"; };
          annotations = {
            summary = "ZFS snapshot for {{ $labels.dataset }} is over 48 hours old on {{ $labels.hostname }}";
            description = "Latest snapshot age: {{ $value | humanizeDuration }}. CRITICAL: Backup data is stale. Immediate investigation required.";
            command = "systemctl status sanoid.service && zfs list -t snapshot {{ $labels.dataset }}";
          };
        };

        # Stale ZFS holds detected
        "zfs-holds-stale" = {
          type = "promql";
          alertname = "ZFSHoldsStale";
          expr = ''
            count(zfs_hold_age_seconds > 21600) by (hostname) > 3
          '';
          for = "2h";
          severity = "medium";
          labels = { service = "backup"; category = "zfs"; };
          annotations = {
            summary = "Multiple stale ZFS holds detected on {{ $labels.hostname }}";
            description = "{{ $value }} holds are older than 6 hours. Backup jobs may have failed. Check: systemctl status restic-zfs-hold-gc.service";
            command = "zfs holds -rH | grep restic- && systemctl status restic-zfs-hold-gc.service";
          };
        };

        # NOTE: Restic backup alerts (restic-backup-failed, restic-backup-stale) are defined
        # in hosts/_modules/nixos/services/backup/monitoring.nix alongside the backup module
      }  # End system health alerts
    ];  # End alerting.rules mkMerge
  };  # End alerting block
}
