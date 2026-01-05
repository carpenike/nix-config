# hosts/forge/infrastructure/nas-monitoring.nix
#
# Prometheus scrape targets and alerts for NAS hosts (nas-0, nas-1)
#
# Since Prometheus runs on forge, all NAS monitoring is configured here:
# - Scrape targets for node_exporter on each NAS
# - Alerts for NAS-specific concerns (ZFS health, disk space, NFS)
#
# The NAS hosts expose node_exporter on port 9100.

{ ... }:

{
  # =============================================================================
  # Prometheus Scrape Targets for NAS Hosts
  # =============================================================================

  services.prometheus.scrapeConfigs = [
    {
      job_name = "nas-0";
      static_configs = [
        {
          targets = [ "nas-0.holthome.net:9100" ];
          labels = {
            instance = "nas-0";
            role = "storage";
            location = "primary";
          };
        }
      ];
      scrape_interval = "30s";
    }
    {
      job_name = "nas-1";
      static_configs = [
        {
          targets = [ "nas-1.holthome.net:9100" ];
          labels = {
            instance = "nas-1";
            role = "backup";
            location = "secondary";
          };
        }
      ];
      scrape_interval = "30s";
    }
  ];

  # =============================================================================
  # NAS-Specific Alerts
  # =============================================================================

  modules.alerting.rules = {
    # =========================================================================
    # Node Exporter Availability
    # =========================================================================

    # DISABLED (2026-01-05): nas-0 is currently offline for maintenance
    # "nas-0-exporter-down" = {
    #   type = "promql";
    #   alertname = "NAS0ExporterDown";
    #   expr = ''up{job="nas-0"} == 0'';
    #   for = "2m";
    #   severity = "critical";
    #   labels = { service = "nas-0"; category = "availability"; };
    #   annotations = {
    #     summary = "NAS-0 node exporter is down";
    #     description = "Cannot collect metrics from nas-0.holthome.net:9100. Check network connectivity and node_exporter service.";
    #     command = "ssh nas-0 systemctl status prometheus-node-exporter";
    #   };
    # };

    "nas-1-exporter-down" = {
      type = "promql";
      alertname = "NAS1ExporterDown";
      expr = ''up{job="nas-1"} == 0'';
      for = "2m";
      severity = "critical";
      labels = { service = "nas-1"; category = "availability"; };
      annotations = {
        summary = "NAS-1 node exporter is down";
        description = "Cannot collect metrics from nas-1.holthome.net:9100. Check network connectivity and node_exporter service.";
        command = "ssh nas-1 systemctl status prometheus-node-exporter";
      };
    };

    # =========================================================================
    # ZFS Pool Health
    # =========================================================================

    "nas-zpool-degraded" = {
      type = "promql";
      alertname = "NASZpoolDegraded";
      expr = ''zfs_pool_health{instance=~"nas-.*"} == 1'';
      for = "1m";
      severity = "critical";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} is DEGRADED on {{ $labels.instance }}";
        description = "A drive may have failed. Run 'zpool status {{ $labels.pool }}' immediately to assess.";
        command = "ssh {{ $labels.instance }} zpool status {{ $labels.pool }}";
      };
    };

    "nas-zpool-faulted" = {
      type = "promql";
      alertname = "NASZpoolFaulted";
      expr = ''zfs_pool_health{instance=~"nas-.*"} >= 2'';
      for = "0m";
      severity = "critical";
      labels = { service = "zfs"; category = "storage"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} is FAULTED on {{ $labels.instance }}";
        description = "Pool is offline or has critical errors. Immediate attention required!";
        command = "ssh {{ $labels.instance }} zpool status {{ $labels.pool }}";
      };
    };

    # =========================================================================
    # Disk Space
    # =========================================================================

    "nas-disk-space-critical" = {
      type = "promql";
      alertname = "NASDiskSpaceCritical";
      expr = ''
        (node_filesystem_avail_bytes{instance=~"nas-.*",fstype!~"tmpfs|fuse.*"}
         / node_filesystem_size_bytes) < 0.05
      '';
      for = "5m";
      severity = "critical";
      labels = { service = "storage"; category = "capacity"; };
      annotations = {
        summary = "Filesystem {{ $labels.mountpoint }} critically low on {{ $labels.instance }}";
        description = "Only {{ $value | humanizePercentage }} available. Immediate cleanup or expansion required.";
        command = "ssh {{ $labels.instance }} df -h {{ $labels.mountpoint }}";
      };
    };

    "nas-disk-space-warning" = {
      type = "promql";
      alertname = "NASDiskSpaceWarning";
      expr = ''
        (node_filesystem_avail_bytes{instance=~"nas-.*",fstype!~"tmpfs|fuse.*"}
         / node_filesystem_size_bytes) < 0.15
      '';
      for = "15m";
      severity = "high";
      labels = { service = "storage"; category = "capacity"; };
      annotations = {
        summary = "Filesystem {{ $labels.mountpoint }} low on space on {{ $labels.instance }}";
        description = "Only {{ $value | humanizePercentage }} available. Plan cleanup or expansion.";
        command = "ssh {{ $labels.instance }} df -h {{ $labels.mountpoint }}";
      };
    };

    # =========================================================================
    # ZFS Pool Capacity (from custom metrics)
    # =========================================================================

    "nas-zpool-capacity-critical" = {
      type = "promql";
      alertname = "NASZpoolCapacityCritical";
      expr = ''
        (zfs_pool_allocated_bytes{instance=~"nas-.*"} / zfs_pool_size_bytes) > 0.90
      '';
      for = "5m";
      severity = "critical";
      labels = { service = "zfs"; category = "capacity"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} is over 90% full on {{ $labels.instance }}";
        description = "Pool capacity is {{ $value | humanizePercentage }}. ZFS performance degrades significantly above 80%.";
        command = "ssh {{ $labels.instance }} zpool list {{ $labels.pool }}";
      };
    };

    "nas-zpool-capacity-warning" = {
      type = "promql";
      alertname = "NASZpoolCapacityWarning";
      expr = ''
        (zfs_pool_allocated_bytes{instance=~"nas-.*"} / zfs_pool_size_bytes) > 0.80
      '';
      for = "30m";
      severity = "high";
      labels = { service = "zfs"; category = "capacity"; };
      annotations = {
        summary = "ZFS pool {{ $labels.pool }} is over 80% full on {{ $labels.instance }}";
        description = "Pool capacity is {{ $value | humanizePercentage }}. Consider expanding or cleaning up.";
        command = "ssh {{ $labels.instance }} zpool list {{ $labels.pool }}";
      };
    };

    # =========================================================================
    # NFS Service Health
    # =========================================================================

    "nas-nfs-down" = {
      type = "promql";
      alertname = "NASNFSDown";
      expr = ''node_systemd_unit_state{instance=~"nas-.*",name="nfs-server.service",state="active"} == 0'';
      for = "2m";
      severity = "critical";
      labels = { service = "nfs"; category = "availability"; };
      annotations = {
        summary = "NFS server is down on {{ $labels.instance }}";
        description = "NFS service is not active. This affects all NFS mounts from this host.";
        command = "ssh {{ $labels.instance }} systemctl status nfs-server.service";
      };
    };

    # =========================================================================
    # Sanoid/Syncoid Health
    # =========================================================================

    "nas-sanoid-failed" = {
      type = "promql";
      alertname = "NASSanoidFailed";
      expr = ''node_systemd_unit_state{instance=~"nas-.*",name="sanoid.service",state="failed"} == 1'';
      for = "5m";
      severity = "high";
      labels = { service = "sanoid"; category = "backup"; };
      annotations = {
        summary = "Sanoid snapshot service failed on {{ $labels.instance }}";
        description = "Automatic ZFS snapshots may not be running. Check sanoid service logs.";
        command = "ssh {{ $labels.instance }} journalctl -u sanoid.service -n 50";
      };
    };

    "nas-syncoid-failed" = {
      type = "promql";
      alertname = "NASSyncoidFailed";
      expr = ''node_systemd_unit_state{instance=~"nas-.*",name="syncoid.service",state="failed"} == 1'';
      for = "5m";
      severity = "high";
      labels = { service = "syncoid"; category = "backup"; };
      annotations = {
        summary = "Syncoid replication service failed on {{ $labels.instance }}";
        description = "ZFS replication may not be running. Check syncoid service logs.";
        command = "ssh {{ $labels.instance }} journalctl -u syncoid.service -n 50";
      };
    };

    # =========================================================================
    # System Health
    # =========================================================================

    "nas-high-load" = {
      type = "promql";
      alertname = "NASHighLoad";
      expr = ''node_load15{instance=~"nas-.*"} > (count by (instance) (node_cpu_seconds_total{instance=~"nas-.*",mode="idle"}) * 2)'';
      for = "15m";
      severity = "medium";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "High system load on {{ $labels.instance }}";
        description = "15-minute load average is {{ $value }}. May indicate I/O saturation or runaway process.";
        command = "ssh {{ $labels.instance }} htop";
      };
    };

    "nas-high-memory" = {
      type = "promql";
      alertname = "NASHighMemory";
      # ZFS ARC aggressively uses RAM for caching but releases it under pressure.
      # Standard (1 - MemAvailable/MemTotal) is misleading because MemAvailable
      # already accounts for some reclaimable memory but not ARC specifically.
      # This query adds ARC size back to available memory for accurate pressure detection.
      # Alert fires only when ACTUAL memory pressure exists (non-ARC usage > 90%).
      expr = ''
        (1 - ((node_memory_MemAvailable_bytes{instance=~"nas-.*"} + node_zfs_arc_size{instance=~"nas-.*"}) / node_memory_MemTotal_bytes{instance=~"nas-.*"})) > 0.90
      '';
      for = "10m";
      severity = "high";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "High memory usage on {{ $labels.instance }} (excluding ZFS ARC)";
        description = "Non-ARC memory usage is {{ $value | humanizePercentage }}. This excludes reclaimable ZFS ARC cache.";
        command = "ssh {{ $labels.instance }} free -h && cat /proc/spl/kstat/zfs/arcstats | grep c_";
      };
    };
  };
}
