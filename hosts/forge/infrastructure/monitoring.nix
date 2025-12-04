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

  # TLS Certificate Monitoring Script (Direct File Access)
  # Reads certificates directly from Caddy's storage directory for reliability
  tlsMetricsScript = pkgs.writeShellScriptBin "export-tls-metrics" ''
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.openssl pkgs.findutils pkgs.gnugrep pkgs.systemd ]}"

    # Default to DEBUG=0 unless the variable is already set
    DEBUG="''${DEBUG:-0}"

    # Helper function for debug logging
    log_debug() {
      if [[ "''${DEBUG}" -eq 1 ]]; then
        echo "DEBUG: $*" >&2
      fi
    }

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/tls.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"
    CADDY_CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"

    # Clean up the temp file on script exit
    trap 'rm -f "''${TMP_METRICS_FILE}"' EXIT

    # Ensure the destination directory exists and is writable
    mkdir -p "$(dirname "''${METRICS_FILE}")"

    # Function to check a certificate file's expiry and extract all SANs
    # Optimized to parse certificate only once for better performance
    check_certificate_file() {
      local certfile="$1"
      log_debug "Checking certificate: $certfile"
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
    log_debug "Starting metrics generation"
    log_debug "METRICS_FILE=$METRICS_FILE"

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
        log_debug "Found ''${#cert_files[@]} certificate files"

        echo "tls_certificates_found ''${#cert_files[@]}"

        # Only iterate if we have certificates (avoids "unbound variable" error with set -u)
        if [ ''${#cert_files[@]} -gt 0 ]; then
          for certfile in "''${cert_files[@]}"; do
            check_certificate_file "$certfile"
          done
        fi
      else
        echo "tls_certificates_found 0"
        # Export a canary metric to detect misconfiguration (directory may not exist yet on fresh installs)
        echo "tls_certificate_check_success{certfile=\"none\",domain=\"caddy.storage.missing\"} 0"
        echo "tls_certificate_expiry_seconds{certfile=\"none\",domain=\"caddy.storage.missing\"} -1"
      fi

      # ACME Challenge Status from Caddy logs
      # NOTE: These are real counters that track cumulative failures since service start
      # They reset when the caddy service restarts
      echo "# HELP caddy_acme_challenges_failed_total Total ACME challenge failures since service start"
      echo "# TYPE caddy_acme_challenges_failed_total counter"

      # Count ACME failures since Caddy service started (not a sliding window)
      # This creates a proper monotonic counter for use with rate() in Prometheus
      # Uses --grep for efficient filtering instead of piping full logs through jq
      CADDY_START_TIME=$(${pkgs.systemd}/bin/systemctl show caddy.service --property=ActiveEnterTimestamp --value)
      if [ -n "$CADDY_START_TIME" ] && [ "$CADDY_START_TIME" != "n/a" ]; then
        # Convert systemd timestamp to a format journalctl accepts
        START_TIMESTAMP=$(date -d "$CADDY_START_TIME" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "1 hour ago")
        # Fallback to 0 if journalctl fails (e.g., due to permissions)
        CHALLENGES_FAILED=$(${pkgs.systemd}/bin/journalctl -u caddy.service --since "$START_TIMESTAMP" --no-pager -q \
          --grep="obtaining certificate.*error|challenge failed|acme.*failed" --case-sensitive=false 2>&1 | wc -l) || CHALLENGES_FAILED=0
      else
        # Fallback if we can't determine service start time
        CHALLENGES_FAILED=$(${pkgs.systemd}/bin/journalctl -u caddy.service --since "1 hour ago" --no-pager -q \
          --grep="obtaining certificate.*error|challenge failed|acme.*failed" --case-sensitive=false 2>&1 | wc -l) || CHALLENGES_FAILED=0
      fi
      log_debug "ACME challenges failed: $CHALLENGES_FAILED"

      echo "caddy_acme_challenges_failed_total ''${CHALLENGES_FAILED}"

      # Caddy Service Health
      echo "# HELP caddy_service_up Caddy service health status (1=up, 0=down)"
      echo "# TYPE caddy_service_up gauge"

      # Use --fail to ensure curl returns a non-zero exit code on HTTP errors
      if ${pkgs.curl}/bin/curl -s --fail --max-time 5 http://localhost:2019/metrics >/dev/null 2>&1; then
        echo "caddy_service_up 1"
        log_debug "Caddy health check: UP"
      else
        echo "caddy_service_up 0"
        log_debug "Caddy health check: DOWN"
      fi

    } > "''${TMP_METRICS_FILE}"

    # Atomic move and set permissions
    mv "''${TMP_METRICS_FILE}" "''${METRICS_FILE}"
    chmod 644 "''${METRICS_FILE}"
    log_debug "Metrics exported successfully to $METRICS_FILE"
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

  # Consolidated systemd configuration for all metrics exporters
  systemd.services = {
    # ZFS metrics exporter service
    zfs-metrics-exporter = {
      description = "ZFS Pool Metrics Exporter for Prometheus";
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # zpool commands require root
        ExecStart = "${zfsMetricsScript}/bin/export-zfs-metrics";
      };
    };

    # TLS metrics exporter service
    tls-metrics-exporter = {
      description = "TLS Certificate Metrics Exporter for Prometheus";
      # Wait for both Caddy and the permission fixer to complete
      # The permission fixer sets ACLs on /var/lib/caddy/.local/share/caddy/certificates
      # so that node-exporter (in caddy group) can read certificates
      after = [ "caddy.service" "fix-caddy-cert-permissions.service" ];
      wants = [ "caddy.service" "fix-caddy-cert-permissions.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "node-exporter";
        Group = "node-exporter";
        WorkingDirectory = "/var/lib/node_exporter";
        ExecStart = "${tlsMetricsScript}/bin/export-tls-metrics";

        # Grant read access to Caddy certificates and write access to node_exporter directory
        # Note: ReadWritePaths must include the parent directory to allow path traversal
        ReadWritePaths = [ "/var/lib/node_exporter" ];
        ReadOnlyPaths = [ "/var/lib/caddy/.local/share/caddy/certificates" ];

        # Capture output to journal for debugging
        StandardOutput = "journal";
        StandardError = "journal";

        # Add timeout to prevent hanging on certificate checks
        TimeoutStartSec = "60s";
      };
    };

    # Container metrics exporter service
    container-metrics-exporter = {
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
  };

  systemd.timers = {
    # ZFS metrics timer
    zfs-metrics-exporter = {
      description = "Run ZFS metrics exporter every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
        Unit = "zfs-metrics-exporter.service";
      };
    };

    # TLS metrics timer
    tls-metrics-exporter = {
      description = "Run TLS metrics exporter every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m"; # Wait for Caddy to start AND permissions to be fixed (fix-caddy runs at 2m + processing time)
        OnUnitActiveSec = "5m"; # Check every 5 minutes
        Unit = "tls-metrics-exporter.service";
      };
    };

    # Container metrics timer
    container-metrics-exporter = {
      description = "Run container metrics exporter every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m"; # Wait for containers to start
        OnUnitActiveSec = "60s"; # Check every minute (balanced resolution vs overhead)
        Unit = "container-metrics-exporter.service";
      };
    };
  };

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
}
