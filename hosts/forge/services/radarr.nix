# hosts/forge/services/radarr.nix
#
# Host-specific configuration for the Radarr service on 'forge'.
# Radarr is a movie collection manager.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.radarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.radarr = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/radarr:6.0.3@sha256:0ebc60aa20afb0df76b52694cee846b7cf7bd96bb0157f3b68b916e77c8142a0";

        # Use shared NFS mount and attach to media services network
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "radarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant media role via claim mapping
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        # Enable backups
        backup = forgeDefaults.backup;

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      modules.alerting.rules."radarr-service-down" =
        forgeDefaults.mkServiceDownAlert "radarr" "Radarr" "movie management";
    })
  ];
}
