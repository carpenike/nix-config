{ lib, config, pkgs, ... }:

let
  # SMART disk health metrics exporter
  # Monitors NVMe and SATA drives for pre-failure indicators
  # NOTE: ZFS, TLS, and container metric scripts live in their co-located files:
  #   - ZFS: infrastructure/observability/prometheus.nix
  #   - TLS: infrastructure/observability/prometheus.nix
  #   - Containers: infrastructure/containerization.nix
  smartMetricsScript = pkgs.writeShellScriptBin "export-smart-metrics" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.smartmontools pkgs.coreutils pkgs.bash pkgs.gnugrep pkgs.gawk ]}"

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/smart.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"

    {
      echo "# HELP smart_device_healthy SMART overall health assessment (1=PASSED, 0=FAILED)"
      echo "# TYPE smart_device_healthy gauge"
      echo "# HELP smart_temperature_celsius Current drive temperature in Celsius"
      echo "# TYPE smart_temperature_celsius gauge"
      echo "# HELP smart_power_on_hours Total power-on hours"
      echo "# TYPE smart_power_on_hours gauge"
      echo "# HELP smart_reallocated_sectors Count of reallocated sectors (SATA)"
      echo "# TYPE smart_reallocated_sectors gauge"
      echo "# HELP smart_media_errors NVMe media and data integrity errors"
      echo "# TYPE smart_media_errors gauge"
      echo "# HELP smart_percentage_used NVMe percentage of rated lifetime used"
      echo "# TYPE smart_percentage_used gauge"
      echo "# HELP smart_available_spare NVMe available spare percentage"
      echo "# TYPE smart_available_spare gauge"
      echo "# HELP smart_critical_warning NVMe critical warning flags (0=none)"
      echo "# TYPE smart_critical_warning gauge"

      # Iterate over block devices (skip partitions, loopbacks, zram)
      for dev in /dev/nvme[0-9]n[0-9] /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        devname=$(basename "$dev")

        # Get SMART health
        health_output=$(smartctl -H "$dev" 2>/dev/null || true)
        if echo "$health_output" | grep -qi "PASSED\|OK"; then
          echo "smart_device_healthy{device=\"$devname\"} 1"
        elif echo "$health_output" | grep -qi "FAILED"; then
          echo "smart_device_healthy{device=\"$devname\"} 0"
        fi

        # NVMe drives
        if [[ "$dev" == /dev/nvme* ]]; then
          smart_json=$(smartctl -A -j "$dev" 2>/dev/null || true)
          if [ -n "$smart_json" ]; then
            temp=$(echo "$smart_json" | awk -F': ' '/"temperature"/{found=1} found && /"current"/{print $2; exit}' | tr -d ' ,')
            poh=$(echo "$smart_json" | awk -F': ' '/"power_on_hours"/{found=1} found && /"raw".*"value"/{print $2; exit}' | tr -d ' ,')
            media_err=$(echo "$smart_json" | awk -F': ' '/"media_errors"/{found=1} found && /"raw".*"value"/{print $2; exit}' | tr -d ' ,')
            pct_used=$(echo "$smart_json" | awk -F': ' '/"percentage_used"/{found=1} found && /"raw".*"value"/{print $2; exit}' | tr -d ' ,')
            avail_spare=$(echo "$smart_json" | awk -F': ' '/"available_spare"/{found=1} found && /"raw".*"value"/{print $2; exit}' | tr -d ' ,')
            crit_warn=$(echo "$smart_json" | awk -F': ' '/"critical_warning"/{found=1} found && /"raw".*"value"/{print $2; exit}' | tr -d ' ,')

            [ -n "$temp" ] && echo "smart_temperature_celsius{device=\"$devname\"} $temp"
            [ -n "$poh" ] && echo "smart_power_on_hours{device=\"$devname\"} $poh"
            [ -n "$media_err" ] && echo "smart_media_errors{device=\"$devname\"} $media_err"
            [ -n "$pct_used" ] && echo "smart_percentage_used{device=\"$devname\"} $pct_used"
            [ -n "$avail_spare" ] && echo "smart_available_spare{device=\"$devname\"} $avail_spare"
            [ -n "$crit_warn" ] && echo "smart_critical_warning{device=\"$devname\"} $crit_warn"
          fi
        fi

        # SATA drives
        if [[ "$dev" == /dev/sd* ]]; then
          smart_output=$(smartctl -A "$dev" 2>/dev/null || true)
          if [ -n "$smart_output" ]; then
            temp=$(echo "$smart_output" | awk '/Temperature_Celsius/{print $10}')
            poh=$(echo "$smart_output" | awk '/Power_On_Hours/{print $10}')
            realloc=$(echo "$smart_output" | awk '/Reallocated_Sector/{print $10}')

            [ -n "$temp" ] && echo "smart_temperature_celsius{device=\"$devname\"} $temp"
            [ -n "$poh" ] && echo "smart_power_on_hours{device=\"$devname\"} $poh"
            [ -n "$realloc" ] && echo "smart_reallocated_sectors{device=\"$devname\"} $realloc"
          fi
        fi
      done
    } > "$TMP_METRICS_FILE"

    mv "$TMP_METRICS_FILE" "$METRICS_FILE"
    chmod 644 "$METRICS_FILE"
  '';
in
{
  imports = [
    # This host is a standard monitored agent.
    ../../common/monitoring-agent.nix
    # This host is also designated as the central monitoring hub.
    ../../common/monitoring-hub.nix
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

  # Consolidated services.prometheus configuration
  services.prometheus = {
    # Host-specific node exporter overrides
    exporters.node = {
      # Note: monitoring-agent.nix enables [ "systemd" ], monitoring module adds "textfile"
      enabledCollectors = lib.mkForce [ "systemd" "textfile" ];
    };

    # PostgreSQL Performance Monitoring via postgres_exporter
    exporters.postgres = {
      enable = true;
      port = 9187;
      # Use peer authentication as postgres user (no password needed)
      runAsLocalSuperUser = true;
      # DataSourceName not needed when using runAsLocalSuperUser

      # Custom queries for forge-specific monitoring
      extraFlags = [
        "--auto-discover-databases"
        "--exclude-databases=template0,template1"
      ];
    };

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

      # PostgreSQL exporter (database performance metrics)
      {
        job_name = "postgres";
        static_configs = [
          { targets = [ "127.0.0.1:9187" ]; labels = { instance = "forge.holthome.net"; }; }
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
    interval = "minutely";
  };

  # NOTE: ZFS, TLS, and container metrics exporters live in their co-located files:
  #   - ZFS metrics: infrastructure/observability/prometheus.nix
  #   - TLS metrics: infrastructure/observability/prometheus.nix
  #   - Container metrics: infrastructure/containerization.nix

  # Alerts for GPU usage (host-level) and instance availability
  modules.alerting.rules."gpu-exporter-stale" = {
    type = "promql";
    alertname = "GpuExporterStale";
    expr = "time() - gpu_metrics_last_run_timestamp > 240";
    for = "1m";
    severity = "high";
    labels = { service = "gpu"; category = "monitoring"; };
    annotations = {
      summary = "GPU exporter stale on {{ $labels.instance }}";
      description = "No GPU metrics collected for >4 minutes. Check timer: systemctl status gpu-metrics-exporter.timer";
    };
  };

  modules.alerting.rules."gpu-exporter-error" = {
    type = "promql";
    alertname = "GpuExporterError";
    expr = "gpu_metrics_error == 1";
    for = "2m";
    severity = "high";
    labels = { service = "gpu"; category = "monitoring"; };
    annotations = {
      summary = "GPU metrics collection failing on {{ $labels.instance }}";
      description = "The gpu-metrics-exporter service is failing to collect metrics. Check service logs: journalctl -u gpu-metrics-exporter.service";
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

  modules.alerting.rules."gpu-engine-stalled" = {
    type = "promql";
    alertname = "GpuEngineStalled";
    expr = ''
      gpu_engine_busy_percent{engine=~"Video.*"} == 0
      and
      max by (hostname)(gpu_engine_busy_percent{engine!~"Video.*"}) > 5
    '';
    for = "5m";
    severity = "medium";
    labels = { service = "gpu"; category = "hardware"; };
    annotations = {
      summary = "GPU engine {{ $labels.engine }} may be stalled on {{ $labels.instance }}";
      description = "The {{ $labels.engine }} has reported 0% utilization for 5 minutes while other GPU engines are active. This could indicate a driver or hardware issue affecting video transcoding.";
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

  # Host reboot detection (replaces fragile systemd boot/shutdown event alerts)
  # Uses node_boot_time_seconds metric which changes when a host reboots
  # More reliable than systemd hooks and provides better context
  modules.alerting.rules."host-rebooted" = {
    type = "promql";
    alertname = "HostRebooted";
    expr = ''changes(node_boot_time_seconds{job="node"}[15m]) > 0'';
    for = "5m";
    severity = "low";
    labels = { service = "monitoring"; category = "system"; };
    annotations = {
      summary = "Host {{ $labels.instance }} has rebooted";
      description = "Host {{ $labels.instance }} has rebooted within the last 15 minutes. This is typically expected for planned maintenance (NixOS updates) but may indicate an unexpected crash or power loss if unplanned.";
    };
  };

  # NOTE: ZFS pool health alerts moved to infrastructure/storage.nix for co-location with ZFS lifecycle management

  # NOTE: TLS/Caddy alerts moved to infrastructure/reverse-proxy.nix for co-location with Caddy configuration
  # NOTE: Container alerts moved to infrastructure/containerization.nix for co-location with container platform config

  # NOTE: PostgreSQL-specific alert rules have been moved to services/postgresql.nix
  # This follows the contribution pattern where each service defines its own monitoring rules.
  # Infrastructure-level alerts (GPU, ZFS, TLS, containers, etc.) remain here as they are
  # host/platform concerns rather than application-specific.

  # Ensure node-exporter can access /dev/dri and systemd journal for TLS monitoring
  users.users.node-exporter.extraGroups = [ "render" "systemd-journal" "caddy" ];

  # SMART disk health monitoring
  # Textfile collector for NVMe/SATA drive health metrics
  systemd.services.smart-metrics-exporter = {
    description = "SMART Disk Health Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "root"; # smartctl requires root
      ExecStart = "${smartMetricsScript}/bin/export-smart-metrics";
    };
  };

  systemd.timers.smart-metrics-exporter = {
    description = "Run SMART metrics exporter every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
      Unit = "smart-metrics-exporter.service";
    };
  };

  # SMART disk health alerts
  modules.alerting.rules."smart-disk-unhealthy" = {
    type = "promql";
    alertname = "SmartDiskUnhealthy";
    expr = "smart_device_healthy == 0";
    for = "1m";
    severity = "critical";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "SMART health check FAILED for {{ $labels.device }} on {{ $labels.instance }}";
      description = "Disk {{ $labels.device }} has failed its SMART self-assessment. Immediate replacement recommended. Check: smartctl -a /dev/{{ $labels.device }}";
    };
  };

  modules.alerting.rules."smart-nvme-media-errors" = {
    type = "promql";
    alertname = "SmartNVMeMediaErrors";
    expr = "smart_media_errors > 0";
    for = "5m";
    severity = "high";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "NVMe media errors detected on {{ $labels.device }} on {{ $labels.instance }}";
      description = "{{ $value }} media/data integrity errors on {{ $labels.device }}. Monitor for growth — may indicate drive degradation.";
    };
  };

  modules.alerting.rules."smart-nvme-wear-high" = {
    type = "promql";
    alertname = "SmartNVMeWearHigh";
    expr = "smart_percentage_used > 80";
    for = "1h";
    severity = "medium";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "NVMe drive {{ $labels.device }} is {{ $value }}% worn on {{ $labels.instance }}";
      description = "Drive {{ $labels.device }} has used {{ $value }}% of its rated write endurance. Plan replacement when approaching 100%.";
    };
  };

  modules.alerting.rules."smart-nvme-spare-low" = {
    type = "promql";
    alertname = "SmartNVMeSpareLow";
    expr = "smart_available_spare < 20";
    for = "5m";
    severity = "high";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "NVMe spare capacity low on {{ $labels.device }} on {{ $labels.instance }}";
      description = "Available spare is {{ $value }}% on {{ $labels.device }}. Drive reliability is degrading.";
    };
  };

  modules.alerting.rules."smart-nvme-critical-warning" = {
    type = "promql";
    alertname = "SmartNVMeCriticalWarning";
    expr = "smart_critical_warning > 0";
    for = "1m";
    severity = "critical";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "NVMe critical warning on {{ $labels.device }} on {{ $labels.instance }}";
      description = "NVMe controller has raised a critical warning flag on {{ $labels.device }}. Immediate attention required. Check: smartctl -a /dev/{{ $labels.device }}";
    };
  };

  modules.alerting.rules."smart-temperature-high" = {
    type = "promql";
    alertname = "SmartTemperatureHigh";
    expr = "smart_temperature_celsius > 70";
    for = "10m";
    severity = "high";
    labels = { service = "system"; category = "hardware"; };
    annotations = {
      summary = "Disk {{ $labels.device }} temperature is {{ $value }}°C on {{ $labels.instance }}";
      description = "Drive temperature exceeds safe threshold. Check case ventilation and ambient temperature.";
    };
  };
}
