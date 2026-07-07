# hosts/forge/services/seerr.nix
#
# Host-specific configuration for Seerr on 'forge'.
# Seerr is a request management service for Plex/Jellyfin/Emby.
# It is the rebranded successor to Overseerr and Jellyseerr.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.seerr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.seerr = {
        # Seerr - Request management for Plex/Jellyfin/Emby
        # Using official ghcr.io/seerr-team/seerr image
        enable = true;
        # Canonical image pin (Renovate manages host-level pins; module default is an unpinned fallback)
        image = "ghcr.io/seerr-team/seerr:sha-adbcf80@sha256:2bfd7605fe24e3edbf704e893ac4b56a40a068facd30d2d0a524b915277a10f6";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Ensure Seerr starts after its dependencies to prevent connection errors during startup
        dependsOn = [ "sonarr" "radarr" ];

        reverseProxy = {
          enable = true;
          hostName = "requests.${config.networking.domain}";
          # No Authelia - Seerr has native authentication with Plex/Jellyfin OAuth
        };

        # Use backup with snapshots helper
        backup = forgeDefaults.mkBackupWithSnapshots "seerr";

        notifications.enable = true;

        # Custom preseed with restricted restore methods
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # Gatus black-box availability monitoring
      modules.services.gatus.contributions.seerr = {
        name = "Seerr";
        group = "Media";
        url = "https://${config.modules.services.seerr.reverseProxy.hostName}";
        interval = "60s";
        conditions = [ "[STATUS] == 200" "[RESPONSE_TIME] < 3000" ];
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/seerr" = forgeDefaults.mkSanoidDataset "seerr";

      # Service availability alert
      modules.alerting.rules."seerr-service-down" =
        forgeDefaults.mkServiceDownAlert "seerr" "Seerr" "request management";

      # Enable external access via Cloudflare Tunnel
      # Seerr uses native Plex/Jellyfin OAuth - no Authelia needed
      modules.services.caddy.virtualHosts.seerr.cloudflare = {
        enable = true;
        tunnel = "forge";
      };
    })
  ];
}
