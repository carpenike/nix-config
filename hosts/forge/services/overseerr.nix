# hosts/forge/services/overseerr.nix
#
# Host-specific configuration for Overseerr on 'forge'.
# Overseerr is a request management service for Plex.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.overseerr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.overseerr = {
        # Overseerr - Request management for Plex
        enable = true;
        image = "lscr.io/linuxserver/overseerr:latest";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Ensure Overseerr starts after its dependencies to prevent connection errors during startup
        dependsOn = [ "sonarr" "radarr" ];

        reverseProxy = {
          enable = true;
          hostName = "requests.holthome.net";
          # No Authelia - Overseerr has native authentication with Plex OAuth
        };

        # Use backup with snapshots helper
        backup = forgeDefaults.mkBackupWithSnapshots "overseerr";

        notifications.enable = true;

        # Custom preseed with restricted restore methods
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/overseerr" = forgeDefaults.mkSanoidDataset "overseerr";

      # Service availability alert
      modules.alerting.rules."overseerr-service-down" =
        forgeDefaults.mkServiceDownAlert "overseerr" "Overseerr" "request management";
    })
  ];
}
