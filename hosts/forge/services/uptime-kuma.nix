{ config, lib, mylib, ... }:
# Uptime Kuma Configuration for forge
#
# Provides uptime monitoring and status pages for homelab services.
# Uses native NixOS service (not containerized) wrapped with homelab patterns.
#
# ARCHITECTURE EVOLUTION:
#
# 1. Container Version (369 lines) - Nov 5, 2025
#    Initially implemented as Podman container with full homelab patterns
#
# 2. Native Wrapper (200 lines) - Nov 5, 2025
#    Discovered NixOS has native uptime-kuma service, pivoted to wrapper approach:
#    - Simpler: ~150 lines vs 369
#    - No Podman dependency
#    - Better NixOS integration
#    - Easier updates via nix flake update
#
# 3. Pragmatic Monitoring (current) - Nov 5, 2025
#    Gemini Pro analysis: Skip uptime-kuma-exporter, use blackbox approach
#    - Uptime Kuma handles notifications for services it monitors
#    - Prometheus monitors Uptime Kuma itself (meta-monitoring via systemd healthcheck)
#    - No additional exporter service = simpler, more reliable
#    - Avoids "monitoring the monitor" complexity trap
#
# Retains all homelab integrations: ZFS, backups, preseed, monitoring, DR.
let
  inherit (lib) optionalAttrs;

  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
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
        enable = resticEnabled;
      } // optionalAttrs resticEnabled {
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" "restic" ];
      };
    };

    # Prometheus alerts for Uptime Kuma
    # ARCHITECTURE: Pragmatic blackbox monitoring approach (Gemini Pro recommendation, Nov 5 2025)
    #
    # MONITORING PHILOSOPHY:
    # - Uptime Kuma monitors downstream services (black-box checks)
    # - Prometheus monitors Uptime Kuma itself (meta-monitoring)
    # - Uptime Kuma's native notification system handles alerts for services it monitors
    # - No uptime-kuma-exporter needed (avoids monitoring-the-monitor complexity)
    #
    # WHY NOT THE EXPORTER?
    # Adding uptime-kuma-exporter creates a new point of failure to get visibility into
    # Uptime Kuma's state. If the exporter breaks, you lose monitoring of the monitor.
    # The real risk is "Is Uptime Kuma completely down?" not "What's the status of each
    # individual monitor?" (Uptime Kuma already notifies about those).
    #
    # This approach uses systemd health checks (already running) to detect if Uptime Kuma
    # is responsive. It's simple, robust, and requires zero additional dependencies.
    # Monitoring alerts using helper library where applicable
    # These are systemd-based alerts (not standard service down patterns)
    modules.alerting.rules = lib.mkIf (config.modules.services.uptime-kuma.enable) {
      # CRITICAL: Service is running but unresponsive (zombie process or frozen)
      # The systemd health check (curl to localhost:3001) is failing
      # This is the PRIMARY alert - if this fires, Uptime Kuma is not working
      # Custom alert - no helper fits this systemd healthcheck pattern
      "uptime-kuma-unhealthy" = mylib.monitoring-helpers.mkThresholdAlert {
        name = "uptime-kuma";
        alertname = "UptimeKumaUnhealthy";
        expr = ''node_systemd_unit_state{name="uptime-kuma-healthcheck.service", state="failed", instance=~".*forge.*"} == 1'';
        threshold = 1;
        for = "0m";
        severity = "critical";
        category = "availability";
        summary = "Uptime Kuma is unhealthy on {{ $labels.instance }}";
        description = "The Uptime Kuma service is running but failing its internal health check (cannot be reached via local curl). The application may be frozen, deadlocked, or the web server crashed. Command: systemctl status uptime-kuma-healthcheck.service uptime-kuma.service && journalctl -u uptime-kuma.service --since '30m'";
      };

      # CRITICAL: Systemd service is stopped or crashed
      # This catches cases where the process isn't running at all
      # Custom alert - systemd-specific monitoring
      "uptime-kuma-service-down" = mylib.monitoring-helpers.mkThresholdAlert {
        name = "uptime-kuma";
        alertname = "UptimeKumaServiceDown";
        expr = ''node_systemd_unit_state{name="uptime-kuma.service", state="active", instance=~".*forge.*"} == 0'';
        threshold = 0;
        for = "2m";
        severity = "critical";
        category = "availability";
        summary = "Uptime Kuma systemd service is not active on {{ $labels.instance }}";
        description = "The uptime-kuma.service is not in 'active' state. It may be stopped, failed, or in restart loop. Command: systemctl status uptime-kuma.service && journalctl -u uptime-kuma.service --since '30m'";
      };
    };
  };
}
