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

  # NOTE: Container metrics collection and alerts have been moved to infrastructure/containerization.nix
  # This follows the co-location principle: container platform config + container monitoring together

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
    ../../../common/monitoring-agent.nix
    # This host is also designated as the central monitoring hub.
    ../../../common/monitoring-hub.nix
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
    # Disable config check at build time because we use runtime secrets
    # (credentials_file for OnCall metrics auth can't be accessed during nix build)
    checkConfig = false;

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
        # `host` label matches Loki's host label for cross-system correlation
        # `instance` remains FQDN for Prometheus-native patterns
        static_configs = [
          { targets = [ "127.0.0.1:9100" ]; labels = { instance = "forge.holthome.net"; host = "forge"; }; }
          # Example for when other hosts are added:
          # { targets = [ "luna.holthome.net:9100" ]; labels = { instance = "luna.holthome.net"; host = "luna"; }; }
          # { targets = [ "nas-1.holthome.net:9100" ]; labels = { instance = "nas-1.holthome.net"; host = "nas-1"; }; }
        ];
      }

      # PostgreSQL exporter (database performance metrics)
      {
        job_name = "postgres";
        static_configs = [
          { targets = [ "127.0.0.1:9187" ]; labels = { instance = "forge.holthome.net"; host = "forge"; }; }
        ];
      }

      # Prometheus self-monitoring
      {
        job_name = "prometheus";
        static_configs = [
          { targets = [ "127.0.0.1:9090" ]; labels = { instance = "forge.holthome.net"; host = "forge"; }; }
        ];
      }

      # Alertmanager monitoring
      {
        job_name = "alertmanager";
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; labels = { instance = "forge.holthome.net"; host = "forge"; }; }
        ];
      }

      # Grafana OnCall metrics
      # OnCall exposes metrics on its main port with Bearer token auth
      {
        job_name = "grafana-oncall";
        metrics_path = "/metrics/";
        static_configs = [
          { targets = [ "127.0.0.1:8094" ]; labels = { instance = "forge.holthome.net"; host = "forge"; service = "grafana-oncall"; }; }
        ];
        authorization = {
          type = "Bearer";
          credentials_file = config.sops.secrets."grafana-oncall/metrics_secret".path;
        };
      }
    ];
  };

  # Enable host-level GPU metrics
  modules.services.gpuMetrics = {
    enable = true;
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

  # NOTE: All alerts moved to their proper co-located locations:
  # - GPU alerts: infrastructure/monitoring.nix (core hardware monitoring)
  # - instance-down, host-rebooted: infrastructure/monitoring.nix (core system monitoring)
  # - ZFS pool alerts: infrastructure/storage.nix (co-located with ZFS lifecycle)
  # - TLS/Caddy alerts: infrastructure/reverse-proxy.nix (co-located with Caddy config)
  # This file configures the Prometheus service itself, not alerts

  # TLS metrics exporter service and timer
  systemd.services.tls-metrics-exporter = {
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

  systemd.timers.tls-metrics-exporter = {
    description = "Run TLS metrics exporter every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m"; # Wait for Caddy to start AND permissions to be fixed (fix-caddy runs at 2m + processing time)
      OnUnitActiveSec = "5m"; # Check every 5 minutes
      Unit = "tls-metrics-exporter.service";
    };
  };

  # NOTE: TLS/Caddy alerts moved to infrastructure/reverse-proxy.nix for co-location with Caddy configuration

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

  # NOTE: PostgreSQL-specific alert rules have been moved to services/postgresql.nix
  # This follows the contribution pattern where each service defines its own monitoring rules.
  # Infrastructure-level alerts (GPU, ZFS, TLS, containers, etc.) remain here as they are
  # host/platform concerns rather than application-specific.

  # Prometheus self-monitoring alert
  modules.alerting.rules."prometheus-down" = {
    type = "promql";
    alertname = "PrometheusDown";
    expr = "up{job=\"prometheus\"} == 0";
    for = "5m";
    severity = "critical";
    labels = { service = "monitoring"; category = "prometheus"; };
    annotations = {
      summary = "Prometheus is down on {{ $labels.instance }}";
      description = "Monitoring system is not functioning. Check prometheus.service status.";
    };
  };

  # Ensure node-exporter can access /dev/dri and systemd journal for TLS monitoring
  users.users.node-exporter.extraGroups = [ "render" "systemd-journal" "caddy" ];

  # Declare Prometheus storage dataset (contribution pattern)
  # Multi-model consensus (GPT-5 + Gemini 2.5 Pro + Gemini 2.5 Flash): 8.7/10 confidence
  # Verdict: Prometheus TSDB is correct tool; ZFS snapshots are excessive for disposable metrics
  modules.storage.datasets.services.prometheus = {
    recordsize = "128K"; # Aligned with Prometheus WAL segments and 2h block files
    compression = "lz4"; # Minimal overhead; TSDB chunks already compressed
    mountpoint = "/var/lib/prometheus2";
    owner = "prometheus";
    group = "prometheus";
    mode = "0755";
    properties = {
      # Industry best practice: Do NOT snapshot Prometheus TSDB (metrics are disposable)
      # Reasoning: 15-day retention doesn't justify 6-month snapshots; configs in Git, data replaceable
      # CoW amplification during TSDB compaction significantly impacts performance under snapshots
      "com.sun:auto-snapshot" = "false"; # Disable snapshots (was: true)
      logbias = "throughput"; # Optimize for streaming writes, not low-latency sync
      primarycache = "metadata"; # Avoid ARC pollution; Prometheus has its own caching
      atime = "off"; # Reduce metadata writes on read-heavy query workloads
    };
  };

  # Declare Prometheus Sanoid policy (no snapshots for disposable metrics)
  modules.backup.sanoid.datasets."tank/services/prometheus" = {
    autosnap = false;
    autoprune = false;
    recursive = false;
  };
}
