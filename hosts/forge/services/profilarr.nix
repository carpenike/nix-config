{ config, ... }:
{
  config.modules.services = {
    # Profilarr - Profile sync for *arr services
    profilarr = {
      enable = true;
      image = "ghcr.io/profilarr/profilarr:latest";
      podmanNetwork = "media-services";  # Enable DNS resolution to *arr services (Sonarr, Radarr)

      # Run daily at 3 AM to sync quality profiles
      schedule = "*-*-* 03:00:00";

      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/profilarr";
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
