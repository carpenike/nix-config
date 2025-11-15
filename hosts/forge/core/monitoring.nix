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
  };
}
