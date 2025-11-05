{ config, lib, ... }:
# Uptime Kuma Configuration for forge
#
# Provides uptime monitoring and status pages for homelab services.
# Uses native NixOS service (not containerized) wrapped with homelab patterns.
#
# ARCHITECTURE PIVOT (Nov 5, 2025):
# Initially implemented as Podman container (369 lines), but discovered NixOS
# has a native uptime-kuma service. Pivoted to native wrapper approach:
#   - Simpler: ~150 lines vs 369
#   - No Podman dependency
#   - Better NixOS integration
#   - Easier updates via nix flake update
#
# Retains all homelab integrations: ZFS, backups, preseed, monitoring, DR.
{
  config = {
    modules.services.uptime-kuma = {
      enable = true;

      # Reverse proxy integration via Caddy
      reverseProxy = {
        enable = true;
        hostName = "status.${config.networking.domain}";
      };

      # Enable health monitoring
      healthcheck.enable = true;

      # Backup application data daily to primary NAS repository
      # ZFS snapshots ensure SQLite database consistency
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/uptime-kuma";
        frequency = "daily";
        tags = [ "monitoring" "uptime-kuma" "forge" ];
      };

      # Enable self-healing restore from backups
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" "restic" ];
      };
    };

    # Prometheus alerts for Uptime Kuma
    modules.alerting.rules = lib.mkIf (config.modules.services.uptime-kuma.enable) {
      "uptime-kuma-down" = {
        type = "promql";
        alertname = "UptimeKumaDown";
        expr = ''up{job="service-uptime-kuma"} == 0'';
        for = "5m";
        severity = "critical";
        labels = { service = "uptime-kuma"; category = "availability"; };
        annotations = {
          summary = "Uptime Kuma is down on {{ $labels.instance }}";
          description = "Uptime Kuma service is not responding to Prometheus scrapes. Check: systemctl status uptime-kuma.service";
          command = "systemctl status uptime-kuma.service && journalctl -u uptime-kuma.service --since '30m'";
        };
      };

      "uptime-kuma-monitor-failing" = {
        type = "promql";
        alertname = "UptimeKumaMonitoredServiceDown";
        # Uptime Kuma /metrics reports status: 1=UP, 2=DOWN
        expr = ''monitor_status{job="service-uptime-kuma"} == 2'';
        for = "2m";
        severity = "high";
        labels = { service = "uptime-kuma"; category = "monitoring"; };
        annotations = {
          summary = "Monitored service '{{ $labels.monitor_name }}' is down";
          description = "Uptime Kuma reports that '{{ $labels.monitor_name }}' is failing checks. Check status page: https://status.${config.networking.domain}";
        };
      };
    };
  };
}
