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

  # TLS Certificate Monitoring Script
  # Monitors certificate expiration and ACME challenge status for all Caddy-managed domains
  tlsMetricsScript = pkgs.writeShellScriptBin "export-tls-metrics" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.openssl pkgs.curl pkgs.gnused pkgs.gawk pkgs.jq ]}"

    METRICS_FILE="/var/lib/node_exporter/textfile_collector/tls.prom"
    TMP_METRICS_FILE="''${METRICS_FILE}.tmp"

    # Get all domains from Caddy configuration
    # Extract hostnames from running Caddy config
    DOMAINS=$(${pkgs.curl}/bin/curl -s http://localhost:2019/config/ 2>/dev/null | \
      ${pkgs.jq}/bin/jq -r '.apps.http.servers[].routes[]?.match[]?.host[]? // empty' 2>/dev/null | \
      sort -u || echo "")

    # Fallback: common forge domains if Caddy API fails
    if [ -z "$DOMAINS" ]; then
      DOMAINS="grafana.holthome.net sonarr.holthome.net dispatcharr.holthome.net plex.holthome.net"
    fi

    # Generate metrics atomically
    (
      echo "# HELP tls_certificate_expiry_seconds Time until TLS certificate expires"
      echo "# TYPE tls_certificate_expiry_seconds gauge"

      for domain in $DOMAINS; do
        if [ -n "$domain" ]; then
          # Get certificate expiration time
          EXPIRY=$(echo | ${pkgs.openssl}/bin/openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            ${pkgs.openssl}/bin/openssl x509 -noout -enddate 2>/dev/null | \
            ${pkgs.gnused}/bin/sed 's/notAfter=//' || echo "")

          if [ -n "$EXPIRY" ]; then
            # Convert to Unix timestamp
            EXPIRY_TIMESTAMP=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
            CURRENT_TIMESTAMP=$(date +%s)
            SECONDS_UNTIL_EXPIRY=$((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP))

            echo "tls_certificate_expiry_seconds{domain=\"$domain\"} $SECONDS_UNTIL_EXPIRY"
          else
            # Certificate check failed - could be ACME in progress or connection issue
            echo "tls_certificate_expiry_seconds{domain=\"$domain\"} -1"
          fi
        fi
      done

      # ACME Challenge Status from Caddy logs
      echo "# HELP caddy_acme_challenges_total Total ACME challenges attempted"
      echo "# TYPE caddy_acme_challenges_total counter"
      echo "# HELP caddy_acme_challenges_failed_total Total failed ACME challenges"
      echo "# TYPE caddy_acme_challenges_failed_total counter"

      # Count ACME events from recent journal logs (last 24 hours)
      CHALLENGES_TOTAL=$(${pkgs.systemd}/bin/journalctl -u caddy.service --since "24 hours ago" --no-pager -q 2>/dev/null | \
        grep -c "acme.*challenge" || echo "0")
      CHALLENGES_FAILED=$(${pkgs.systemd}/bin/journalctl -u caddy.service --since "24 hours ago" --no-pager -q 2>/dev/null | \
        grep -c -i "acme.*\(error\|fail\)" || echo "0")

      echo "caddy_acme_challenges_total $CHALLENGES_TOTAL"
      echo "caddy_acme_challenges_failed_total $CHALLENGES_FAILED"

      # Caddy Service Health
      echo "# HELP caddy_service_up Caddy service health status (1=up, 0=down)"
      echo "# TYPE caddy_service_up gauge"

      # Check if Caddy admin API responds
      if ${pkgs.curl}/bin/curl -s --max-time 5 http://localhost:2019/metrics >/dev/null 2>&1; then
        echo "caddy_service_up 1"
      else
        echo "caddy_service_up 0"
      fi

    ) > "$TMP_METRICS_FILE"

    # Atomic move and set permissions
    mv "$TMP_METRICS_FILE" "$METRICS_FILE"
    chmod 644 "$METRICS_FILE"
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

  # ZFS Storage Monitoring Alerts
  modules.alerting.rules."zfs-pool-unhealthy" = {
    type = "promql";
    alertname = "ZfsPoolUnhealthy";
    expr = "zfs_pool_health > 0";
    for = "5m";
    severity = "critical";
    labels = { service = "zfs"; category = "storage"; };
    annotations = {
      summary = "ZFS pool {{ $labels.pool }} is unhealthy";
      description = "Pool {{ $labels.pool }} has status {{ $labels.health }}. Immediate investigation required.";
    };
  };

  modules.alerting.rules."zfs-capacity-critical" = {
    type = "promql";
    alertname = "ZfsPoolCapacityCritical";
    expr = "zfs_pool_capacity_percent > 95";
    for = "5m";
    severity = "critical";
    labels = { service = "zfs"; category = "capacity"; };
    annotations = {
      summary = "ZFS pool {{ $labels.pool }} critically full";
      description = "Pool {{ $labels.pool }} is {{ $value }}% full. Data loss imminent.";
    };
  };

  modules.alerting.rules."zfs-capacity-warning" = {
    type = "promql";
    alertname = "ZfsPoolCapacityHigh";
    expr = "zfs_pool_capacity_percent > 85";
    for = "15m";
    severity = "high";
    labels = { service = "zfs"; category = "capacity"; };
    annotations = {
      summary = "ZFS pool {{ $labels.pool }} reaching capacity";
      description = "Pool {{ $labels.pool }} is {{ $value }}% full.";
    };
  };

  modules.alerting.rules."zfs-fragmentation-high" = {
    type = "promql";
    alertname = "ZfsPoolFragmentationHigh";
    expr = "zfs_pool_fragmentation_percent > 50";
    for = "30m";
    severity = "medium";
    labels = { service = "zfs"; category = "performance"; };
    annotations = {
      summary = "ZFS pool {{ $labels.pool }} highly fragmented";
      description = "Pool {{ $labels.pool }} is {{ $value }}% fragmented. Consider running defragmentation.";
    };
  };


  # TLS metrics exporter service and timer
  systemd.services.tls-metrics-exporter = {
    description = "TLS Certificate Metrics Exporter for Prometheus";
    serviceConfig = {
      Type = "oneshot";
      User = "node-exporter"; # Run as node-exporter user for file permissions
      ExecStart = "${tlsMetricsScript}/bin/export-tls-metrics";
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

  # TLS Certificate Monitoring Alerts
  modules.alerting.rules."tls-certificate-expiring-soon" = {
    type = "promql";
    alertname = "TlsCertificateExpiringSoon";
    expr = "tls_certificate_expiry_seconds > 0 and tls_certificate_expiry_seconds < 604800"; # 7 days
    for = "5m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} expires in {{ $value | humanizeDuration }}. Renew soon.";
    };
  };

  modules.alerting.rules."tls-certificate-expiring-critical" = {
    type = "promql";
    alertname = "TlsCertificateExpiringCritical";
    expr = "tls_certificate_expiry_seconds > 0 and tls_certificate_expiry_seconds < 172800"; # 2 days
    for = "0m"; # Immediate alert
    severity = "critical";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring very soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} expires in {{ $value | humanizeDuration }}. URGENT renewal required.";
    };
  };

  modules.alerting.rules."tls-certificate-check-failed" = {
    type = "promql";
    alertname = "TlsCertificateCheckFailed";
    expr = "tls_certificate_expiry_seconds == -1";
    for = "10m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate check failed for {{ $labels.domain }}";
      description = "Cannot retrieve certificate info for {{ $labels.domain }}. Check connectivity and ACME status.";
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

  # Ensure exporter can access /dev/dri
  users.users.node-exporter.extraGroups = [ "render" ];
}
