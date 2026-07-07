{ ... }:

{
  # Core system health monitoring for forge
  # These alerts monitor fundamental OS-level metrics: CPU, memory, disk, systemd units
  # Infrastructure service alerts (Prometheus, Caddy, etc.) are co-located with their service definitions

  modules.alerting.rules = {
    # Node exporter down - cannot collect system metrics
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
    # Note: NAS instances use the ZFS-aware NASHighMemory alert in nas-monitoring.nix
    # which accounts for ARC cache being reclaimable under pressure
    "high-memory-usage" = {
      type = "promql";
      alertname = "HighMemoryUsage";
      expr = ''
        (1 - (node_memory_MemAvailable_bytes{instance!~"nas-.*"} / node_memory_MemTotal_bytes{instance!~"nas-.*"})) > 0.90
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

    # Critical memory pressure - host is nearly out of memory
    # Fires at 95% (vs HighMemoryUsage at 90%) for immediate attention
    "memory-pressure-critical" = {
      type = "promql";
      alertname = "MemoryPressureCritical";
      expr = ''
        (1 - (node_memory_MemAvailable_bytes{instance!~"nas-.*"} / node_memory_MemTotal_bytes{instance!~"nas-.*"})) > 0.95
      '';
      for = "5m";
      severity = "critical";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "Critical memory pressure on {{ $labels.instance }}";
        description = "Memory usage is {{ $value | humanizePercentage }}. OOM kills imminent. Investigate immediately.";
        command = "ps aux --sort=-%mem | head -20";
      };
    };

    # NFS mount errors - detect stale or errored NFS mounts
    # Critical for backup reliability (restic, pgBackRest depend on NFS)
    "nfs-mount-error" = {
      type = "promql";
      alertname = "NFSMountError";
      expr = ''
        node_filesystem_device_error{fstype="nfs4"} > 0
      '';
      for = "5m";
      severity = "high";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "NFS mount error on {{ $labels.mountpoint }} on {{ $labels.instance }}";
        description = "NFS filesystem at {{ $labels.mountpoint }} has device errors. Backups may be failing silently. Check: mount | grep nfs";
      };
    };

    # NFS mount disappeared - filesystem was expected but is gone
    "nfs-mount-missing" = {
      type = "promql";
      alertname = "NFSMountMissing";
      expr = ''
        absent(node_filesystem_avail_bytes{mountpoint="/mnt/nas-backup"}) == 1
        and on() (node_time_seconds - node_boot_time_seconds) > 600
      '';
      for = "15m";
      severity = "high";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "NFS backup mount missing on {{ $labels.instance }}";
        description = "The /mnt/nas-backup mount is not present. Restic backups will fail. Check NAS connectivity and automount.";
      };
    };

    # Systemd timer not firing - detect timers that stopped triggering
    # Uses node_systemd_timer_last_trigger_seconds from node_exporter
    # Excludes transient/ephemeral timers (podman healthchecks have hash names)
    # and weekly-cadence timers (covered by SystemdWeeklyTimerStale below).
    # Threshold 36h: the slowest remaining cadence is daily (+RandomizedDelaySec),
    # so 36h means a missed run without flapping on catch-up after reboots.
    "systemd-timer-stale" = {
      type = "promql";
      alertname = "SystemdTimerStale";
      expr = ''
        (time() - node_systemd_timer_last_trigger_seconds{name!~".*[0-9a-f]{64}.*", name!~"(pgbackrest-check|backup-verification-report|zfs-scrub|restic-prune-.*)\\.timer"}) > 129600
        and node_systemd_unit_state{name=~".*\\.timer", state="active"} == 1
      '';
      for = "30m";
      severity = "medium";
      labels = { service = "system"; category = "systemd"; };
      annotations = {
        summary = "Systemd timer {{ $labels.name }} hasn't fired in 36+ hours on {{ $labels.instance }}";
        description = "Timer {{ $labels.name }} last triggered {{ $value | humanizeDuration }} ago. Check: systemctl list-timers {{ $labels.name }}";
      };
    };

    # Weekly-cadence timers get their own staleness window (9 days = one missed
    # weekly run with margin). Keep this name list in sync with the exclusion in
    # systemd-timer-stale above.
    "systemd-weekly-timer-stale" = {
      type = "promql";
      alertname = "SystemdWeeklyTimerStale";
      expr = ''
        (time() - node_systemd_timer_last_trigger_seconds{name=~"(pgbackrest-check|backup-verification-report|zfs-scrub|restic-prune-.*)\\.timer"}) > 86400 * 9
        and node_systemd_unit_state{name=~".*\\.timer", state="active"} == 1
      '';
      for = "30m";
      severity = "medium";
      labels = { service = "system"; category = "systemd"; };
      annotations = {
        summary = "Weekly systemd timer {{ $labels.name }} hasn't fired in 9+ days on {{ $labels.instance }}";
        description = "Timer {{ $labels.name }} last triggered {{ $value | humanizeDuration }} ago. Check: systemctl list-timers {{ $labels.name }}";
      };
    };

    # Generic textfile-collector staleness watchdog
    # A stale .prom file freezes its gauges at the last written values, so alerts
    # based on them (pool health, SMART, TLS expiry, containers, UPS, pgBackRest)
    # go silently blind. All files matched here are produced by timers running at
    # least every 15 minutes, so 2h of no updates means the producer is broken.
    # Deliberately excluded:
    #   - syncoid-*.prom      -> dedicated ZFSReplicationExporterStale (30m, storage.nix)
    #   - GPU metrics         -> dedicated GpuExporterStale on gpu_metrics_last_run_timestamp
    #   - event-driven files  -> preseed/backup-report files update rarely by design
    "textfile-collector-stale" = {
      type = "promql";
      alertname = "TextfileCollectorStale";
      expr = ''
        time() - node_textfile_mtime_seconds{file=~"(zfs|smart|tls|containers|ups|zfs_snapshots|zpool_errors|pgbackrest)\\.prom"} > 2 * 3600
      '';
      for = "15m";
      severity = "medium";
      labels = { service = "system"; category = "monitoring"; };
      annotations = {
        summary = "Textfile collector {{ $labels.file }} is stale on {{ $labels.instance }}";
        description = "Metrics file {{ $labels.file }} has not been updated in {{ $value | humanizeDuration }} (producers run every <=15m). Alerts derived from it are blind. Check the matching *-exporter/*-metrics timer and service.";
        command = "ls -lh /var/lib/node_exporter/textfile_collector/{{ $labels.file }} && systemctl list-timers | grep -Ei 'metrics|exporter'";
      };
    };

    # Escalation: half a day without updates means storage/hardware alerting has
    # been blind long enough to hide a real failure window.
    "textfile-collector-stale-critical" = {
      type = "promql";
      alertname = "TextfileCollectorStaleCritical";
      expr = ''
        time() - node_textfile_mtime_seconds{file=~"(zfs|smart|tls|containers|ups|zfs_snapshots|zpool_errors|pgbackrest)\\.prom"} > 12 * 3600
      '';
      for = "15m";
      severity = "critical";
      labels = { service = "system"; category = "monitoring"; };
      annotations = {
        summary = "Textfile collector {{ $labels.file }} stale for 12+ hours on {{ $labels.instance }}";
        description = "Metrics file {{ $labels.file }} has not been updated in {{ $value | humanizeDuration }}. Storage/hardware alert coverage from this file has been blind for half a day.";
        command = "ls -lh /var/lib/node_exporter/textfile_collector/ && systemctl --failed";
      };
    };
  };
}
