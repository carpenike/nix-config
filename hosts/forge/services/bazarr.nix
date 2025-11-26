# hosts/forge/services/bazarr.nix
#
# Host-specific configuration for the Bazarr service on 'forge'.
# Bazarr is a subtitle manager for Sonarr and Radarr.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.bazarr.enable;
in
{
  config = lib.mkMerge [
    {
      modules.services.bazarr = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/bazarr:1.5.3@sha256:2f1c32cb1420b2e56f60cfdf7823737eb501fdb2c13669429d23ab3a02e9ad90";

        # Bazarr needs to access both TV and movie directories
        tvDir = "/mnt/data/media/tv";
        moviesDir = "/mnt/data/media/movies";

        # Attach to media services network for DNS resolution to Sonarr and Radarr
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Configure dependencies on Sonarr and Radarr
        # API keys are automatically injected via SOPS templates
        # Use container names for DNS resolution within media-services network
        dependencies = {
          sonarr = {
            enable = true;
            url = "http://sonarr:8989";
          };
          radarr = {
            enable = true;
            url = "http://radarr:7878";
          };
        };

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "bazarr.holthome.net";

          # Protect via Pocket ID + caddy-security; use media claim for authorization
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
      # Co-located Service Monitoring
      modules.alerting.rules."bazarr-service-down" =
        forgeDefaults.mkServiceDownAlert "bazarr" "Bazarr" "subtitle manager";
    })
  ];
}
