{ lib, config, pkgs, ... }:

let
  # ZFS metrics exporter script - safe alternative to node_exporter ZFS collector
  # Uses zpool commands only (no statfs() calls that cause kernel hangs)
  zfsMetricsScript = pkgs.writeShellScriptBin "export-zfs-metrics" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.zfs pkgs.coreutils pkgs.bash pkgs.gnused ]}"

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/zfs.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"

    # Ensure root privileges (zpool commands require root)
    if [[ "$(id -u)" -ne 0 ]]; then
       echo "This script must be run as root" >&2
       exit 1
    fi

    # Generate metrics atomically
    (
      # ZFS Pool Health Status
      echo "# HELP zfs_pool_health Health status of ZFS pool (0=ONLINE, 1=DEGRADED, 2=FAULTED, 3=OFFLINE, 4=UNAVAIL, 5=REMOVED)"
      echo "# TYPE zfs_pool_health gauge"
      zpool list -H -o name,health | while read -r pool health; do
        status=0
        case "$health" in
          ONLINE)   status=0 ;;
          DEGRADED) status=1 ;;
          FAULTED)  status=2 ;;
          OFFLINE)  status=3 ;;
          UNAVAIL)  status=4 ;;
          REMOVED)  status=5 ;;
        esac
        echo "zfs_pool_health{pool=\"$pool\",health=\"$health\"} $status"
      done

      # ZFS Pool Capacity
      echo "# HELP zfs_pool_capacity_percent ZFS pool capacity used percentage"
      echo "# TYPE zfs_pool_capacity_percent gauge"
      zpool list -H -o name,capacity | while read -r pool capacity; do
        capacity_num=$(echo "$capacity" | sed 's/%$//')
        echo "zfs_pool_capacity_percent{pool=\"$pool\"} $capacity_num"
      done

      # ZFS Pool Fragmentation
      echo "# HELP zfs_pool_fragmentation_percent ZFS pool fragmentation percentage"
      echo "# TYPE zfs_pool_fragmentation_percent gauge"
      zpool list -H -o name,frag | while read -r pool frag; do
        frag_num=$(echo "$frag" | sed 's/%$//')
        echo "zfs_pool_fragmentation_percent{pool=\"$pool\"} $frag_num"
      done

    ) > "$TMP_METRICS_FILE"

    # Atomic move and set permissions
    mv "$TMP_METRICS_FILE" "$METRICS_FILE"
    chmod 644 "$METRICS_FILE"
  '';

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
        echo "''${container_stats}" | ${pkgs.jq}/bin/jq -r '.[] |
          "container_cpu_percent{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.CPU | sub("%$"; "") | tonumber) // 0 | tostring) + "\n" +
          "container_memory_usage_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.MemUsage | split(" / ")[0] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_memory_limit_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.MemUsage | split(" / ")[1] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_memory_percent{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.MemPerc | sub("%$"; "") | tonumber) // 0 | tostring) + "\n" +
          "container_network_input_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.NetIO | split(" / ")[0] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_network_output_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.NetIO | split(" / ")[1] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_block_input_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.BlockIO | split(" / ")[0] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_block_output_bytes{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.BlockIO | split(" / ")[1] | sub("B$"; "") | sub("kB$"; "000") | sub("MB$"; "000000") | sub("GB$"; "000000000") | tonumber) // 0 | tostring) + "\n" +
          "container_pids_current{name=\"" + .Name + "\",id=\"" + .ID[0:12] + "\"} " + ((.PIDs | tonumber) // 0 | tostring)
        ' 2>/dev/null || true
      fi

      # Parse container list for status and metadata
      if [[ "''${container_list}" != "[]" ]] && [[ -n "''${container_list}" ]]; then
        echo "''${container_list}" | ${pkgs.jq}/bin/jq -r '.[] |
          "container_up{name=\"" + (.Names[0] // "unknown") + "\",id=\"" + .Id[0:12] + "\",image=\"" + .Image + "\",status=\"" + .State + "\"} " + (if .State == "running" then "1" else "0" end) + "\n" +
          "container_restart_count{name=\"" + (.Names[0] // "unknown") + "\",id=\"" + .Id[0:12] + "\",image=\"" + .Image + "\"} " + ((.RestartCount | tonumber) // 0 | tostring)
        ' 2>/dev/null || true
      fi

      # Container health check status for running containers
      if [[ "''${container_list}" != "[]" ]] && [[ -n "''${container_list}" ]]; then
        echo "''${container_list}" | ${pkgs.jq}/bin/jq -r '.[] | select(.State == "running") | .Names[0] // "unknown"' 2>/dev/null | while read -r name; do
          if [[ -n "$name" ]]; then
            # Get health status using podman inspect
            health_status=$(${pkgs.podman}/bin/podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$name" 2>/dev/null || echo "unknown")

            # Convert health status to numeric value
            metric_value=2  # unknown
            case "$health_status" in
              healthy)
                metric_value=0
                ;;
              unhealthy)
                metric_value=1
                ;;
              starting)
                metric_value=3
                ;;
            esac

            echo "container_health_status{name=\"$name\",health=\"$health_status\"} $metric_value"
          fi
        done 2>/dev/null || true
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
              echo "container_service_active{service=\"''${service_name}\"} 1"
            else
              echo "container_service_active{service=\"''${service_name}\"} 0"
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

  # TLS Certificate Monitoring Script (Direct File Access)
  # Reads certificates directly from Caddy's storage directory for reliability
  tlsMetricsScript = pkgs.writeShellScriptBin "export-tls-metrics" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.openssl pkgs.findutils pkgs.gnugrep pkgs.systemd ]}"

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/tls.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"
    CADDY_CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"

    # Clean up the temp file on script exit
    trap 'rm -f "''${TMP_METRICS_FILE}"' EXIT

    # Function to check a certificate file's expiry and extract all SANs
    # Optimized to parse certificate only once for better performance
    check_certificate_file() {
      local certfile="$1"
      local cert_filename
      cert_filename=$(basename "$certfile")

      # Parse certificate once and cache the output
      local cert_text
      cert_text=$(${pkgs.openssl}/bin/openssl x509 -noout -text -in "$certfile" 2>/dev/null)

      if [[ -z "$cert_text" ]]; then
        # Certificate is unreadable or malformed
        echo "tls_certificate_check_success{certfile=\"$cert_filename\",domain=\"unknown\"} 0"
        echo "tls_certificate_expiry_seconds{certfile=\"$cert_filename\",domain=\"unknown\"} -1"
        return
      fi

      # Extract all SANs (Subject Alternative Names) from cached text
      local sans
      sans=$(echo "$cert_text" | ${pkgs.gnugrep}/bin/grep -oP 'DNS:\K[^,\s]+' || echo "")

      # Use first SAN or CN as fallback identifier for error reporting
      local primary_domain
      primary_domain=$(echo "$sans" | head -1)
      if [[ -z "$primary_domain" ]]; then
        primary_domain=$(echo "$cert_text" | ${pkgs.gnused}/bin/sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' || echo "unknown")
      fi

      # Get certificate expiry date from the cached text
      local expiry_date
      expiry_date=$(echo "$cert_text" | ${pkgs.gnugrep}/bin/grep 'Not After' | ${pkgs.gnused}/bin/sed 's/.*Not After[[:space:]]*:[[:space:]]*//')

      if [[ -z "''${expiry_date}" ]]; then
        # Could not extract expiry date
        echo "tls_certificate_check_success{certfile=\"$cert_filename\",domain=\"$primary_domain\"} 0"
        echo "tls_certificate_expiry_seconds{certfile=\"$cert_filename\",domain=\"$primary_domain\"} -1"
        return
      fi

      # Convert to epoch timestamp
      local current_ts expiry_ts
      current_ts=$(date +%s)
      expiry_ts=$(date -d "''${expiry_date}" +%s 2>/dev/null || echo "0")

      if [[ "''${expiry_ts}" -eq 0 ]]; then
        # Date parsing failed
        echo "tls_certificate_check_success{certfile=\"$cert_filename\",domain=\"$primary_domain\"} 0"
        echo "tls_certificate_expiry_seconds{certfile=\"$cert_filename\",domain=\"$primary_domain\"} -1"
        return
      fi

      local expiry_seconds=$((expiry_ts - current_ts))

      # Export metrics for all SANs found in the certificate
      if [[ -n "''${sans}" ]]; then
        while IFS= read -r domain; do
          [[ -z "$domain" ]] && continue
          echo "tls_certificate_check_success{certfile=\"$cert_filename\",domain=\"$domain\"} 1"
          echo "tls_certificate_expiry_seconds{certfile=\"$cert_filename\",domain=\"$domain\"} ''${expiry_seconds}"
        done <<< "$sans"
      else
        # Fallback to primary domain if no SANs found
        echo "tls_certificate_check_success{certfile=\"$cert_filename\",domain=\"$primary_domain\"} 1"
        echo "tls_certificate_expiry_seconds{certfile=\"$cert_filename\",domain=\"$primary_domain\"} ''${expiry_seconds}"
      fi
    }

    # Generate metrics atomically
    {
      echo "# HELP tls_certificate_check_success Whether certificate file was successfully read and parsed"
      echo "# TYPE tls_certificate_check_success gauge"
      echo "# HELP tls_certificate_expiry_seconds Time until TLS certificate expires"
      echo "# TYPE tls_certificate_expiry_seconds gauge"
      echo "# HELP tls_certificates_found Total number of certificate files found"
      echo "# TYPE tls_certificates_found gauge"

      # Find all certificate files in Caddy's storage directory
      if [[ -d "''${CADDY_CERT_DIR}" ]]; then
        mapfile -t cert_files < <(find "''${CADDY_CERT_DIR}" -type f -name "*.crt")
        echo "tls_certificates_found ''${#cert_files[@]}"

        for certfile in "''${cert_files[@]}"; do
          check_certificate_file "$certfile"
        done
      else
        echo "tls_certificates_found 0"
        echo "# ERROR: Caddy certificate directory not found: ''${CADDY_CERT_DIR}" >&2
        # Export a canary metric to detect misconfiguration
        echo "tls_certificate_check_success{certfile=\"none\",domain=\"caddy.storage.missing\"} 0"
        echo "tls_certificate_expiry_seconds{certfile=\"none\",domain=\"caddy.storage.missing\"} -1"
      fi

      # ACME Challenge Status from Caddy logs
      echo "# HELP caddy_acme_challenges_total Total ACME challenges attempted"
      echo "# TYPE caddy_acme_challenges_total counter"
      echo "# HELP caddy_acme_challenges_failed_total Total failed ACME challenges"
      echo "# TYPE caddy_acme_challenges_failed_total counter"

      # This command will fail if 'node-exporter' is not in the 'systemd-journal' group
      # We fetch logs once, and `|| true` ensures the script doesn't exit on permission error
      journal_logs=$(${pkgs.systemd}/bin/journalctl -u caddy.service --since "24 hours ago" --no-pager -q 2>/dev/null || true)
      CHALLENGES_TOTAL=$(echo "''${journal_logs}" | ${pkgs.gnugrep}/bin/grep "acme.*challenge" | wc -l)
      CHALLENGES_FAILED=$(echo "''${journal_logs}" | ${pkgs.gnugrep}/bin/grep -i "acme.*\(error\|fail\)" | wc -l)

      echo "caddy_acme_challenges_total ''${CHALLENGES_TOTAL}"
      echo "caddy_acme_challenges_failed_total ''${CHALLENGES_FAILED}"

      # Caddy Service Health
      echo "# HELP caddy_service_up Caddy service health status (1=up, 0=down)"
      echo "# TYPE caddy_service_up gauge"

      # Use --fail to ensure curl returns a non-zero exit code on HTTP errors
      if ${pkgs.curl}/bin/curl -s --fail --max-time 5 http://localhost:2019/metrics >/dev/null 2>&1; then
        echo "caddy_service_up 1"
      else
        echo "caddy_service_up 0"
      fi

    } > "''${TMP_METRICS_FILE}"

    # Atomic move and set permissions
    mv "''${TMP_METRICS_FILE}" "''${METRICS_FILE}"
    chmod 644 "''${METRICS_FILE}"
  '';
in
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
    vendor = "intel";
    interval = "minutely";
  };

  # ZFS metrics exporter service and timer
  systemd.services.zfs-metrics-exporter = {
    description = "ZFS Pool Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "root"; # zpool commands require root
      ExecStart = "${zfsMetricsScript}/bin/export-zfs-metrics";
    };
  };

  systemd.timers.zfs-metrics-exporter = {
    description = "Run ZFS metrics exporter every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "1m";
      Unit = "zfs-metrics-exporter.service";
    };
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

  # ZFS Storage Monitoring Alerts
  modules.alerting.rules."zfs-pool-unhealthy" = {
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

  modules.alerting.rules."zfs-capacity-critical" = {
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

  modules.alerting.rules."zfs-capacity-warning" = {
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

  modules.alerting.rules."zfs-fragmentation-high" = {
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


  # TLS metrics exporter service and timer
  systemd.services.tls-metrics-exporter = {
    description = "TLS Certificate Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "node-exporter";
      Group = "node-exporter";
      ExecStart = "${tlsMetricsScript}/bin/export-tls-metrics";

      # Grant write access to the textfile collector directory
      # This is necessary because of systemd's default sandboxing in NixOS
      ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];

      # Add timeout to prevent hanging on certificate checks
      TimeoutStartSec = "60s";
    };
  };

  systemd.timers.tls-metrics-exporter = {
    description = "Run TLS metrics exporter every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";    # Wait for Caddy to start
      OnUnitActiveSec = "5m";  # Check every 5 minutes
      Unit = "tls-metrics-exporter.service";
    };
  };

  # Container metrics exporter service and timer
  systemd.services.container-metrics-exporter = {
    description = "Container Resource Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "root";  # Run as root to access systemd-managed containers
      ExecStart = "${containerMetricsScript}/bin/export-container-metrics";

      # Grant write access to the textfile collector directory
      ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];

      # Remove socket environment - use default podman context as root
      # Environment = [ "PODMAN_HOST=unix:///run/podman/podman.sock" ];

      # Add timeout to prevent hanging on podman commands
      TimeoutStartSec = "30s";
    };
  };

  systemd.timers.container-metrics-exporter = {
    description = "Run container metrics exporter every 30 seconds";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";     # Wait for containers to start
      OnUnitActiveSec = "30s";  # Check every 30 seconds for real-time monitoring
      Unit = "container-metrics-exporter.service";
    };
  };

  # TLS Certificate Monitoring Alerts
  modules.alerting.rules."tls-certificate-expiring-soon" = {
    type = "promql";
    alertname = "TlsCertificateExpiringSoon";
    expr = "tls_certificate_check_success == 1 and tls_certificate_expiry_seconds < 604800"; # 7 days
    for = "5m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} ({{ $labels.certfile }}) expires in {{ $value | humanizeDuration }}. Renew soon.";
    };
  };

  modules.alerting.rules."tls-certificate-expiring-critical" = {
    type = "promql";
    alertname = "TlsCertificateExpiringCritical";
    expr = "tls_certificate_check_success == 1 and tls_certificate_expiry_seconds < 172800"; # 2 days
    for = "0m"; # Immediate alert
    severity = "critical";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring very soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} ({{ $labels.certfile }}) expires in {{ $value | humanizeDuration }}. URGENT renewal required.";
    };
  };

  modules.alerting.rules."tls-certificate-check-failed" = {
    type = "promql";
    alertname = "TlsCertificateCheckFailed";
    expr = "tls_certificate_check_success == 0";
    for = "10m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate check failed for {{ $labels.domain }}";
      description = "Cannot parse certificate file {{ $labels.certfile }} for domain {{ $labels.domain }}. Certificate may be malformed or unreadable.";
    };
  };

  modules.alerting.rules."acme-challenges-failing" = {
    type = "promql";
    alertname = "AcmeChallengesFailing";
    expr = "increase(caddy_acme_challenges_failed_total[1h]) > 0";
    for = "5m";
    severity = "high";
    labels = { service = "caddy"; category = "acme"; };
    annotations = {
      summary = "ACME challenges failing";
      description = "{{ $value }} ACME challenges have failed in the last hour. Check Caddy logs and DNS configuration.";
    };
  };

  modules.alerting.rules."caddy-certificate-storage-missing" = {
    type = "promql";
    alertname = "CaddyCertificateStorageMissing";
    expr = "tls_certificate_check_success{domain=\"caddy.storage.missing\"} == 0";
    for = "5m";
    severity = "critical";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "Caddy certificate storage directory is missing";
      description = "The TLS metrics exporter cannot find the Caddy certificate directory. This indicates a serious configuration or storage issue.";
    };
  };

  modules.alerting.rules."tls-certificates-all-missing" = {
    type = "promql";
    alertname = "TlsCertificatesAllMissing";
    expr = ''tls_certificates_found == 0 and absent(tls_certificate_check_success{domain="caddy.storage.missing"})'';
    for = "15m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "No TLS certificates found in Caddy storage";
      description = "The TLS metrics exporter found 0 certificate files in the Caddy storage directory, but the directory itself exists. This might indicate a problem with Caddy's certificate management, storage, or permissions.";
    };
  };

  modules.alerting.rules."caddy-service-down" = {
    type = "promql";
    alertname = "CaddyServiceDown";
    expr = "caddy_service_up == 0";
    for = "2m";
    severity = "critical";
    labels = { service = "caddy"; category = "availability"; };
    annotations = {
      summary = "Caddy service is down";
      description = "Caddy reverse proxy is not responding. All web services may be unavailable.";
    };
  };

  # Container Resource Monitoring Alerts
  modules.alerting.rules."container-down" = {
    type = "promql";
    alertname = "ContainerDown";
    expr = "container_up == 0";
    for = "2m";
    severity = "high";
    labels = { service = "containers"; category = "availability"; };
    annotations = {
      summary = "Container {{ $labels.name }} is down";
      description = "Container {{ $labels.name }} ({{ $labels.image }}) is not running. Check systemd service.";
    };
  };

  modules.alerting.rules."container-high-memory" = {
    type = "promql";
    alertname = "ContainerHighMemory";
    expr = "container_memory_percent > 90";
    for = "5m";
    severity = "high";
    labels = { service = "containers"; category = "resources"; };
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
    labels = { service = "containers"; category = "resources"; };
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
    labels = { service = "containers"; category = "stability"; };
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
    labels = { service = "containers"; category = "availability"; };
    annotations = {
      summary = "Container service {{ $labels.service }} is inactive";
      description = "Systemd service for {{ $labels.service }} is not active. Check service status.";
    };
  };

  modules.alerting.rules."podman-system-issues" = {
    type = "promql";
    alertname = "PodmanSystemIssues";
    expr = "podman_containers_running < podman_containers_total and podman_containers_total > 0";
    for = "5m";
    severity = "medium";
    labels = { service = "containers"; category = "system"; };
    annotations = {
      summary = "Some containers are not running";
      description = "{{ $labels.value }} out of {{ $labels.total }} containers are stopped. Check container status.";
    };
  };

  modules.alerting.rules."container-unhealthy" = {
    type = "promql";
    alertname = "ContainerUnhealthy";
    expr = "container_health_status == 1";
    for = "3m";
    severity = "high";
    labels = { service = "containers"; category = "health"; };
    annotations = {
      summary = "Container {{ $labels.name }} is unhealthy";
      description = "Container {{ $labels.name }} health check is failing (status: {{ $labels.health }}). Check container logs.";
    };
  };

  # PostgreSQL Performance Monitoring via postgres_exporter
  services.prometheus.exporters.postgres = {
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


  # PostgreSQL Performance Alerts
  modules.alerting.rules."postgres-down" = {
    type = "promql";
    alertname = "PostgresDown";
    expr = "pg_up == 0";
    for = "2m";
    severity = "critical";
    labels = { service = "postgresql"; category = "availability"; };
    annotations = {
      summary = "PostgreSQL is down on {{ $labels.instance }}";
      description = "PostgreSQL database server is not responding. Check service status.";
    };
  };

  modules.alerting.rules."postgres-too-many-connections" = {
    type = "promql";
    alertname = "PostgresTooManyConnections";
    expr = "pg_stat_database_numbackends / pg_settings_max_connections * 100 > 80";
    for = "5m";
    severity = "high";
    labels = { service = "postgresql"; category = "capacity"; };
    annotations = {
      summary = "PostgreSQL connection usage high on {{ $labels.instance }}";
      description = "PostgreSQL is using {{ $value }}% of max connections. Consider increasing max_connections or investigating connection leaks.";
    };
  };

  modules.alerting.rules."postgres-slow-queries" = {
    type = "promql";
    alertname = "PostgresSlowQueries";
    expr = "increase(pg_stat_database_tup_returned[5m]) / increase(pg_stat_database_tup_fetched[5m]) < 0.1";
    for = "10m";
    severity = "medium";
    labels = { service = "postgresql"; category = "performance"; };
    annotations = {
      summary = "PostgreSQL slow queries detected on {{ $labels.instance }}";
      description = "Database {{ $labels.datname }} has low efficiency ratio. Check for missing indexes or inefficient queries.";
    };
  };

  modules.alerting.rules."postgres-deadlocks" = {
    type = "promql";
    alertname = "PostgresDeadlocks";
    expr = "increase(pg_stat_database_deadlocks[1h]) > 0";
    for = "0m";
    severity = "medium";
    labels = { service = "postgresql"; category = "performance"; };
    annotations = {
      summary = "PostgreSQL deadlocks detected on {{ $labels.instance }}";
      description = "Database {{ $labels.datname }} has {{ $value }} deadlocks in the last hour. Review transaction patterns.";
    };
  };

  modules.alerting.rules."postgres-replication-lag" = {
    type = "promql";
    alertname = "PostgresReplicationLag";
    expr = "pg_replication_lag > 300";
    for = "5m";
    severity = "high";
    labels = { service = "postgresql"; category = "replication"; };
    annotations = {
      summary = "PostgreSQL replication lag high on {{ $labels.instance }}";
      description = "Replication lag is {{ $value }} seconds. Check network and standby performance.";
    };
  };

  modules.alerting.rules."postgres-wal-files-high" = {
    type = "promql";
    alertname = "PostgresWalFilesHigh";
    expr = "pg_stat_archiver_archived_count - pg_stat_archiver_failed_count < 100";
    for = "15m";
    severity = "medium";
    labels = { service = "postgresql"; category = "archiving"; };
    annotations = {
      summary = "PostgreSQL WAL archiving falling behind on {{ $labels.instance }}";
      description = "WAL archiving is not keeping up. Check archive destination and performance.";
    };
  };

  modules.alerting.rules."postgres-database-size-large" = {
    type = "promql";
    alertname = "PostgresDatabaseSizeLarge";
    expr = "pg_database_size_bytes > 5 * 1024 * 1024 * 1024"; # 5GB
    for = "30m";
    severity = "medium";
    labels = { service = "postgresql"; category = "capacity"; };
    annotations = {
      summary = "PostgreSQL database {{ $labels.datname }} is large on {{ $labels.instance }}";
      description = "Database {{ $labels.datname }} is {{ $value }} bytes (>5GB). Consider cleanup or archiving.";
    };
  };

  # Ensure node-exporter can access /dev/dri and systemd journal for TLS monitoring
  users.users.node-exporter.extraGroups = [ "render" "systemd-journal" ];
}
