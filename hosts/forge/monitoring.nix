{ lib, config, ... }:

{
  imports = [
    # This host is a standard monitored agent.
    ../common/monitoring-agent.nix
    # This host is also designated as the central monitoring hub.
    ../common/monitoring-hub.nix
  ];

  # Enable textfile collector via the monitoring module
  # This ensures the directory is created with correct permissions (2770 node-exporter:node-exporter)
  modules.monitoring = {
    enable = true;
    nodeExporter = {
      enable = true;
      textfileCollector.enable = true;
    };
  };

  # Host-specific overrides for the node-exporter agent on 'forge'.
  # Note: ZFS collector disabled due to kernel hangs when snapshot unmount operations are pending.
  # The ZFS collector calls statfs() which can block indefinitely in zfsctl_snapshot_unmount_delay().
  # We use custom textfile collectors for critical ZFS metrics instead.
  services.prometheus.exporters.node = {
    # Note: monitoring-agent.nix enables [ "systemd" ], monitoring module adds "textfile"
    enabledCollectors = lib.mkForce [ "systemd" "textfile" ];
  };

  # Define the scrape targets for this instance of the monitoring hub.
  # If the hub were moved to another host, this block would move with it.
  services.prometheus = {
    # Wire Prometheus to Alertmanager for alert delivery
    alertmanagers = [{
      static_configs = [{
        targets = [ "127.0.0.1:9093" ];
      }];
      scheme = "http";
    }];

    # Load alert rules from the alerting module
    # Rules are co-located with services and automatically aggregated
    ruleFiles = [ config.modules.alerting.prometheus.ruleFilePath ];

    scrapeConfigs = [
      # Node exporter (system metrics + textfile collectors)
      {
        job_name = "node";
        # List all hosts that this Prometheus instance should scrape.
        static_configs = [
          { targets = [ "127.0.0.1:9100" ]; labels = { instance = "forge.holthome.net"; }; }
          # Example for when other hosts are added:
          # { targets = [ "luna.holthome.net:9100" ]; labels = { instance = "luna"; }; }
          # { targets = [ "nas-1.holthome.net:9100" ]; labels = { instance = "nas-1"; }; }
        ];
      }

      # Prometheus self-monitoring
      {
        job_name = "prometheus";
        static_configs = [
          { targets = [ "127.0.0.1:9090" ]; labels = { instance = "forge.holthome.net"; }; }
        ];
      }

      # Alertmanager monitoring
      {
        job_name = "alertmanager";
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; labels = { instance = "forge.holthome.net"; }; }
        ];
      }
    ];
  };

  # Enable host-level GPU metrics
  modules.services.gpuMetrics = {
    enable = true;
    vendor = "intel";
    interval = "minutely";
  };

  # Alerts for GPU usage (host-level) and instance availability
  modules.alerting.rules."gpu-exporter-stale" = {
      type = "promql";
      alertname = "GpuExporterStale";
      expr = "time() - gpu_metrics_last_run_timestamp > 600";
      for = "0m";
      severity = "high";
      labels = { service = "gpu"; category = "monitoring"; };
      annotations = {
        summary = "GPU exporter stale on {{ $labels.instance }}";
        description = "No GPU metrics collected for >10 minutes. Check timer: systemctl status gpu-metrics-exporter.timer";
      };
    };

  modules.alerting.rules."gpu-util-high" = {
      type = "promql";
      alertname = "GpuUtilHigh";
      expr = "gpu_utilization_percent > 80";
      for = "10m";
      severity = "medium";
      labels = { service = "gpu"; category = "capacity"; };
      annotations = {
        summary = "High GPU utilization on {{ $labels.instance }}";
        description = "GPU utilization above 80% for 10m. Investigate Plex/Dispatcharr transcoding load.";
      };
    };

  modules.alerting.rules."instance-down" = {
    type = "promql";
    alertname = "InstanceDown";
    expr = "up{job=\"node\"} == 0";
    for = "2m";
    severity = "critical";
    labels = { service = "monitoring"; category = "availability"; };
    annotations = {
      summary = "Instance down: {{ $labels.instance }}";
      description = "Node exporter target {{ $labels.instance }} is down. Dependency-aware inhibitions will suppress child alerts (e.g., replication).";
    };
  };



  # Ensure exporter can access /dev/dri
  users.users.node-exporter.extraGroups = [ "render" ];
}
