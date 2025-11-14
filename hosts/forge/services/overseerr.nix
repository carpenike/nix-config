{ config, ... }:
{
  config.modules.services = {
    # Overseerr - Request management for Plex
    overseerr = {
      enable = true;
      image = "lscr.io/linuxserver/overseerr:latest";
      podmanNetwork = "media-services";  # Enable DNS resolution to Sonarr, Radarr, and Plex
      healthcheck.enable = true;

      # Ensure Overseerr starts after its dependencies to prevent connection errors during startup
      dependsOn = [ "sonarr" "radarr" ];

      reverseProxy = {
        enable = true;
        hostName = "requests.holthome.net";
        # No Authelia - Overseerr has native authentication with Plex OAuth
      };
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/overseerr";
      };
      notifications.enable = true;
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ];
      };
    };
  };
}
