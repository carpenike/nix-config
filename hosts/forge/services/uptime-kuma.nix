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
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.uptime-kuma.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.uptime-kuma = {
        enable = true;

        # Reverse proxy integration via Caddy
        reverseProxy = {
          enable = true;
          hostName = "status.${config.networking.domain}";
        };

        # Enable health monitoring
        healthcheck.enable = true;

        # Backup using forgeDefaults helper with custom tags
        backup = forgeDefaults.mkBackupWithTags "uptime-kuma" (forgeDefaults.backupTags.monitoring ++ [ "uptime-kuma" "forge" ]);

        # Enable self-healing restore from backups using forgeDefaults
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration (was missing!)
      modules.backup.sanoid.datasets."tank/services/uptime-kuma" =
        forgeDefaults.mkSanoidDataset "uptime-kuma";

      # Service-down alert using forgeDefaults helper
      modules.alerting.rules."uptime-kuma-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "uptime-kuma" "UptimeKuma" "status monitoring";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.uptime-kuma = {
        group = "Monitoring";
        name = "Uptime Kuma";
        icon = "uptime-kuma";
        href = "https://status.holthome.net";
        description = "Service status monitoring";
        siteMonitor = "http://localhost:3001";
      };

      # Custom unhealthy alert (unique pattern - healthcheck.service state monitoring)
      # This catches zombie/frozen processes where service is "active" but unresponsive
      modules.alerting.rules."uptime-kuma-unhealthy" = mylib.monitoring-helpers.mkThresholdAlert {
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
    })
  ];
}
