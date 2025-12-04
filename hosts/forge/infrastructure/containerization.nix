{ lib, pkgs, ... }:

let
  # Container Resource Monitoring Script
  # Monitors Podman container resource usage, health, and performance metrics
  containerMetricsScript = pkgs.writeShellScriptBin "export-container-metrics" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.podman pkgs.gnused pkgs.gawk pkgs.jq pkgs.gnugrep pkgs.systemd ]}"

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/containers.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"

    # Clean up the temp file on script exit
    trap 'rm -f "''${TMP_METRICS_FILE}"' EXIT

    # Get all running containers with stats
    # podman stats --no-stream returns JSON with resource usage
    container_stats=$(${pkgs.podman}/bin/podman stats --no-stream --format json 2>/dev/null || echo "[]")

    # Get container list with additional metadata
    container_list=$(${pkgs.podman}/bin/podman ps --all --format json 2>/dev/null || echo "[]")

    # Generate metrics atomically
    {
      echo "# HELP container_cpu_percent CPU usage percentage"
      echo "# TYPE container_cpu_percent gauge"
      echo "# HELP container_memory_usage_bytes Memory usage in bytes"
      echo "# TYPE container_memory_usage_bytes gauge"
      echo "# HELP container_memory_limit_bytes Memory limit in bytes"
      echo "# TYPE container_memory_limit_bytes gauge"
      echo "# HELP container_memory_percent Memory usage percentage"
      echo "# TYPE container_memory_percent gauge"
      echo "# HELP container_network_input_bytes Network input bytes"
      echo "# TYPE container_network_input_bytes counter"
      echo "# HELP container_network_output_bytes Network output bytes"
      echo "# TYPE container_network_output_bytes counter"
      echo "# HELP container_block_input_bytes Block device input bytes"
      echo "# TYPE container_block_input_bytes counter"
      echo "# HELP container_block_output_bytes Block device output bytes"
      echo "# TYPE container_block_output_bytes counter"
      echo "# HELP container_pids_current Number of processes in container"
      echo "# TYPE container_pids_current gauge"
      echo "# HELP container_up Container running status (1=running, 0=stopped)"
      echo "# TYPE container_up gauge"
      echo "# HELP container_restart_count Container restart count"
      echo "# TYPE container_restart_count counter"
      echo "# HELP container_health_status Container health check status (0=healthy, 1=unhealthy, 2=unknown, 3=starting)"
      echo "# TYPE container_health_status gauge"

      # Parse container stats (running containers only)
      if [[ "''${container_stats}" != "[]" ]] && [[ -n "''${container_stats}" ]]; then
        echo "''${container_stats}" | ${pkgs.jq}/bin/jq -r '
          def bytes(v):
            if (v | test("^0B$")) then 0
            elif (v | test("[kK]i?B$")) then ((v | sub("[kK]i?B$"; "") | tonumber) * 1024)
            elif (v | test("[mM]i?B$")) then ((v | sub("[mM]i?B$"; "") | tonumber) * 1048576)
            elif (v | test("[gG]i?B$")) then ((v | sub("[gG]i?B$"; "") | tonumber) * 1073741824)
            elif (v | test("[tT]i?B$")) then ((v | sub("[tT]i?B$"; "") | tonumber) * 1099511627776)
            elif (v | test("B$")) then (v | sub("B$"; "") | tonumber)
            else 0 end;

          .[] |
          "container_cpu_percent{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.cpu_percent | sub("%$"; "") | tonumber) // 0 | tostring) + "\n" +
          "container_memory_usage_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.mem_usage | split(" / ")[0] | bytes(.)) // 0 | tostring) + "\n" +
          "container_memory_limit_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.mem_usage | split(" / ")[1] | bytes(.)) // 0 | tostring) + "\n" +
          "container_memory_percent{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.mem_percent | sub("%$"; "") | tonumber) // 0 | tostring) + "\n" +
          "container_network_input_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.net_io | split(" / ")[0] | bytes(.)) // 0 | tostring) + "\n" +
          "container_network_output_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.net_io | split(" / ")[1] | bytes(.)) // 0 | tostring) + "\n" +
          "container_block_input_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.block_io | split(" / ")[0] | bytes(.)) // 0 | tostring) + "\n" +
          "container_block_output_bytes{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.block_io | split(" / ")[1] | bytes(.)) // 0 | tostring) + "\n" +
          "container_pids_current{name=\"" + .name + "\",id=\"" + .id[0:12] + "\"} " + ((.pids | tonumber) // 0 | tostring)
        ' 2>/dev/null || true
      fi

      # Parse container list for status and metadata
      if [[ "''${container_list}" != "[]" ]] && [[ -n "''${container_list}" ]]; then
        echo "''${container_list}" | ${pkgs.jq}/bin/jq -r '.[] |
          "container_up{name=\"" + (.Names[0] // "unknown") + "\",id=\"" + .Id[0:12] + "\",image=\"" + .Image + "\",status=\"" + .State + "\"} " + (if .State == "running" then "1" else "0" end) + "\n" +
          "container_restart_count{name=\"" + (.Names[0] // "unknown") + "\",id=\"" + .Id[0:12] + "\",image=\"" + .Image + "\"} " + ((.Restarts | tonumber) // 0 | tostring)
        ' 2>/dev/null || true
      fi

      # Container health check status for running containers (optimized bulk query)
      if [[ "''${container_list}" != "[]" ]] && [[ -n "''${container_list}" ]]; then
        # Get all running container IDs
        running_ids=$(echo "''${container_list}" | ${pkgs.jq}/bin/jq -r '.[] | select(.State == "running") | .Id' 2>/dev/null)

        if [[ -n "$running_ids" ]]; then
          # Single bulk inspect call for all running containers
          health_data=$(${pkgs.podman}/bin/podman inspect --format '{{json .}}' $running_ids 2>/dev/null | ${pkgs.jq}/bin/jq -s '.' 2>/dev/null || echo "[]")

          if [[ "''${health_data}" != "[]" ]]; then
            echo "''${health_data}" | ${pkgs.jq}/bin/jq -r '
              .[] |
              (.State.Health.Status // "unknown") as $status |
              (if $status == "healthy" then 0
               elif $status == "unhealthy" then 1
               elif $status == "starting" then 3
               else 2 end) as $metric_value |
              "container_health_status{name=\"" + (.Name | sub("^/"; "")) + "\",health=\"" + $status + "\"} " + ($metric_value | tostring)
            ' 2>/dev/null || true
          fi
        fi
      fi

      # Container service health from systemd (dynamic discovery)
      echo "# HELP container_service_active Systemd container service active status"
      echo "# TYPE container_service_active gauge"

      # Dynamically discover all podman-*.service units
      # This automatically picks up any container services without hardcoding
      ${pkgs.systemd}/bin/systemctl list-units --type=service --no-legend --no-pager 'podman-*.service' 2>/dev/null | \
        ${pkgs.gawk}/bin/awk '{print $1}' | \
        ${pkgs.gnused}/bin/sed 's/\.service$//' | \
        while read -r service_unit; do
          if [[ -n "$service_unit" && "$service_unit" =~ ^podman- ]]; then
            service_name=$(echo "$service_unit" | ${pkgs.gnused}/bin/sed 's/podman-//')
            if ${pkgs.systemd}/bin/systemctl is-active "$service_unit.service" >/dev/null 2>&1; then
              echo "container_service_active{name=\"''${service_name}\"} 1"
            else
              echo "container_service_active{name=\"''${service_name}\"} 0"
            fi
          fi
        done

      # Podman system info
      echo "# HELP podman_containers_total Total number of containers"
      echo "# TYPE podman_containers_total gauge"
      echo "# HELP podman_containers_running Number of running containers"
      echo "# TYPE podman_containers_running gauge"
      echo "# HELP podman_containers_stopped Number of stopped containers"
      echo "# TYPE podman_containers_stopped gauge"

      # Get total containers count
      total_containers=$(echo "''${container_list}" | ${pkgs.jq}/bin/jq '. | length' 2>/dev/null || echo "0")
      running_containers=$(echo "''${container_list}" | ${pkgs.jq}/bin/jq '[.[] | select(.State == "running")] | length' 2>/dev/null || echo "0")
      stopped_containers=$(echo "''${container_list}" | ${pkgs.jq}/bin/jq '[.[] | select(.State != "running")] | length' 2>/dev/null || echo "0")

      echo "podman_containers_total ''${total_containers}"
      echo "podman_containers_running ''${running_containers}"
      echo "podman_containers_stopped ''${stopped_containers}"

    } > "''${TMP_METRICS_FILE}"

    # Atomic move and set permissions
    mv "''${TMP_METRICS_FILE}" "''${METRICS_FILE}"
    chmod 644 "''${METRICS_FILE}"
  '';
in
{
  # Podman containerization configuration for forge
  # Defines container networking, metrics collection, and container health monitoring
  # This follows the co-location principle: platform config + platform monitoring together

  modules.virtualization.podman = {
    enable = true;
    networks = {
      "media-services" = {
        driver = "bridge";
        # DNS resolution is enabled by default for bridge networks
        # Containers on this network can reach each other by container name
      };
    };
  };

  # Container metrics exporter service and timer
  systemd.services.container-metrics-exporter = {
    description = "Container Resource Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "root"; # Run as root to access systemd-managed containers
      ExecStart = "${containerMetricsScript}/bin/export-container-metrics";

      # Grant write access to the textfile collector directory
      ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];

      # Add timeout to prevent hanging on podman commands
      TimeoutStartSec = "30s";
    };
  };

  systemd.timers.container-metrics-exporter = {
    description = "Run container metrics exporter every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m"; # Wait for containers to start
      OnUnitActiveSec = "60s"; # Check every minute (balanced resolution vs overhead)
      Unit = "container-metrics-exporter.service";
    };
  };

  # Container Resource Monitoring Alerts
  modules.alerting.rules."container-down" = {
    type = "promql";
    alertname = "ContainerDown";
    # Only alert for containers NOT managed by systemd (manual containers)
    expr = "container_up == 0 unless on(name) container_service_active";
    for = "2m";
    severity = "medium";
    labels = { service = "container"; category = "availability"; };
    annotations = {
      summary = "Unmanaged container {{ $labels.name }} is down";
      description = "Container {{ $labels.name }} ({{ $labels.image }}) is not running. This is a manually-started container without systemd management.";
    };
  };

  modules.alerting.rules."container-high-memory" = {
    type = "promql";
    alertname = "ContainerHighMemory";
    expr = "container_memory_percent > 80";
    for = "5m";
    severity = "high";
    labels = { service = "container"; category = "resources"; };
    annotations = {
      summary = "Container {{ $labels.name }} high memory usage";
      description = "Container {{ $labels.name }} is using {{ $value }}% of its memory limit.";
    };
  };

  modules.alerting.rules."container-high-cpu" = {
    type = "promql";
    alertname = "ContainerHighCpu";
    expr = "container_cpu_percent > 80";
    for = "10m";
    severity = "medium";
    labels = { service = "container"; category = "resources"; };
    annotations = {
      summary = "Container {{ $labels.name }} high CPU usage";
      description = "Container {{ $labels.name }} is using {{ $value }}% CPU for 10+ minutes.";
    };
  };

  modules.alerting.rules."container-restarts-frequent" = {
    type = "promql";
    alertname = "ContainerRestartsFrequent";
    expr = "increase(container_restart_count[1h]) > 3";
    for = "5m";
    severity = "high";
    labels = { service = "container"; category = "stability"; };
    annotations = {
      summary = "Container {{ $labels.name }} restarting frequently";
      description = "Container {{ $labels.name }} has restarted {{ $value }} times in the last hour.";
    };
  };

  modules.alerting.rules."container-service-inactive" = {
    type = "promql";
    alertname = "ContainerServiceInactive";
    expr = "container_service_active == 0";
    for = "2m";
    severity = "critical";
    labels = { service = "container"; category = "availability"; };
    annotations = {
      summary = "Container service {{ $labels.name }} is inactive";
      description = "Systemd service for {{ $labels.name }} is not active. Check service status.";
    };
  };

  modules.alerting.rules."container-unhealthy" = {
    type = "promql";
    alertname = "ContainerUnhealthy";
    expr = "container_health_status == 1";
    for = "3m";
    severity = "high";
    labels = { service = "container"; category = "health"; };
    annotations = {
      summary = "Container {{ $labels.name }} is unhealthy";
      description = "Container {{ $labels.name }} health check is failing (status: {{ $labels.health }}). Check container logs.";
    };
  };

  modules.alerting.rules."container-stuck-starting" = {
    type = "promql";
    alertname = "ContainerStuckStarting";
    expr = "container_health_status == 3";
    for = "10m";
    severity = "high";
    labels = { service = "container"; category = "health"; };
    annotations = {
      summary = "Container {{ $labels.name }} stuck in starting state";
      description = "Container {{ $labels.name }} has been in 'starting' state for over 10 minutes. It may be failing to initialize properly. Check container logs.";
    };
  };

  modules.alerting.rules."container-high-disk-io" = {
    type = "promql";
    alertname = "ContainerHighDiskIO";
    expr = "rate(container_block_input_bytes[5m]) + rate(container_block_output_bytes[5m]) > 52428800";
    for = "10m";
    severity = "medium";
    labels = { service = "container"; category = "resources"; };
    annotations = {
      summary = "Container {{ $labels.name }} has high disk I/O";
      description = "Container {{ $labels.name }} is averaging over 50 MB/s of disk I/O ({{ $value | humanize }}B/s). This could indicate a runaway process or performance issue.";
    };
  };

  modules.alerting.rules."container-managed-down" = {
    type = "promql";
    alertname = "ManagedContainerDown";
    expr = "container_up == 0 and on(name) container_service_active == 1";
    for = "3m";
    severity = "critical";
    labels = { service = "container"; category = "availability"; };
    annotations = {
      summary = "Managed container {{ $labels.name }} is down but service is active";
      description = "The container {{ $labels.name }} is not running, but its systemd service is still active. The service may be in a failed state or unable to restart the container.";
    };
  };

  modules.alerting.rules."container-health-unknown" = {
    type = "promql";
    alertname = "ContainerHealthUnknown";
    expr = "container_health_status == 2";
    for = "15m";
    severity = "low";
    labels = { service = "container"; category = "health"; };
    annotations = {
      summary = "Container {{ $labels.name }} has an unknown health status";
      description = "The health status for container {{ $labels.name }} is unknown. This may be because no health check is configured. Consider adding one to improve monitoring reliability.";
    };
  };
}
