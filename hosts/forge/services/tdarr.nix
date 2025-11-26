{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.tdarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.tdarr = {
        # Tdarr - Transcoding automation
      enable = true;
      image = "ghcr.io/haveagitgat/tdarr:latest";
      nfsMountDependency = "media";
      podmanNetwork = forgeDefaults.podmanNetwork;  # Enable DNS resolution for media library access
      healthcheck.enable = true;

      # Intel GPU hardware acceleration
      # Pass the entire /dev/dri directory to the container. This is more robust
      # than hardcoding specific device nodes, which can change between reboots.
      # The application inside the container will automatically find the correct
      # render node for VA-API transcoding.
      accelerationDevices = [ "/dev/dri" ];

      # Resource limits for transcoding workloads
      resources = {
        memory = "4G";
        memoryReservation = "2G";
        cpus = "4.0";
      };

      reverseProxy = {
        enable = true;
        hostName = "tdarr.holthome.net";
        caddySecurity = forgeDefaults.caddySecurity.media;
      };
      # Only backup config/database, not cache
      backup = forgeDefaults.mkBackupWithSnapshots "tdarr";
      notifications.enable = true;
      preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/tdarr" = forgeDefaults.mkSanoidDataset "tdarr";

      # Service availability alert
      modules.alerting.rules."tdarr-service-down" =
        forgeDefaults.mkServiceDownAlert "tdarr" "Tdarr" "transcoding automation";
    })
  ];
}
