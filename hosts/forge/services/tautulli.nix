# hosts/forge/services/tautulli.nix
#
# Host-specific configuration for Tautulli on 'forge'.
# Tautulli provides Plex media server monitoring and statistics.
#
# ARCHITECTURE:
# Uses native NixOS service (not containerized) wrapped with homelab patterns.
# See hosts/_modules/nixos/services/tautulli/default.nix for module details.
#
# AUTHENTICATION:
# Tautulli does NOT support proxy auth bypass. Authentication is handled by
# Tautulli itself (Plex auth or HTTP Basic). No PocketID to avoid double-auth.
#
# ACCESS:
# LAN-only access via reverse proxy. Not exposed via Cloudflare Tunnel.

{ config, lib, mylib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.tautulli.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.tautulli = {
        enable = true;

        # Reverse proxy integration via Caddy (LAN-only, no PocketID)
        # Tautulli has built-in authentication (Plex or HTTP Basic)
        reverseProxy = {
          enable = true;
          hostName = "tautulli.${config.networking.domain}";
          # No caddySecurity - Tautulli handles its own auth
        };

        # Enable health monitoring
        healthcheck.enable = true;

        # Backup using forgeDefaults helper with custom tags
        backup = forgeDefaults.mkBackupWithTags "tautulli" (forgeDefaults.backupTags.media ++ [ "tautulli" "plex-monitoring" "forge" ]);

        # Enable self-healing restore from backups using forgeDefaults
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };

      # Homepage dashboard contribution with Tautulli widget
      modules.services.homepage.contributions.tautulli = {
        group = "Media";
        name = "Tautulli";
        icon = "tautulli";
        href = "https://tautulli.holthome.net";
        description = "Plex media server monitoring and statistics";
        siteMonitor = "http://localhost:8181";
        widget = {
          type = "tautulli";
          url = "http://localhost:8181";
          key = "{{HOMEPAGE_VAR_TAUTULLI_API_KEY}}";
          enableUser = true;
          showEpisodeNumber = true;
        };
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/tautulli" =
        forgeDefaults.mkSanoidDataset "tautulli";

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."tautulli-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "tautulli" "Tautulli" "Plex monitoring";

      # Custom unhealthy alert (healthcheck.service state monitoring)
      # Catches zombie/frozen processes where service is "active" but unresponsive
      modules.alerting.rules."tautulli-unhealthy" = mylib.monitoring-helpers.mkThresholdAlert {
        name = "tautulli";
        alertname = "TautulliUnhealthy";
        expr = ''node_systemd_unit_state{name="tautulli-healthcheck.service", state="failed", instance=~".*forge.*"} == 1'';
        for = "0m";
        severity = "critical";
        category = "availability";
        summary = "Tautulli is unhealthy on {{ $labels.instance }}";
        description = "The Tautulli service is running but failing its internal health check (cannot be reached via local curl). The application may be frozen, deadlocked, or the web server crashed. Command: systemctl status tautulli-healthcheck.service tautulli.service && journalctl -u tautulli.service --since '30m'";
      };
    })
  ];
}
