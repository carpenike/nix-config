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
        image = "ghcr.io/seerr-team/seerr:sha-b66b361";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Ensure Seerr starts after its dependencies to prevent connection errors during startup
        dependsOn = [ "sonarr" "radarr" ];

        reverseProxy = {
          enable = true;
          hostName = "requests.holthome.net";
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
