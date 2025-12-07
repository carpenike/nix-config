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
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork; # Enable DNS resolution for media library access
        healthcheck.enable = true;

        # Intel GPU hardware acceleration
        # Pass the entire /dev/dri directory to the container. This is more robust
        # than hardcoding specific device nodes, which can change between reboots.
        # The application inside the container will automatically find the correct
        # render node for VA-API transcoding.
        accelerationDevices = [ "/dev/dri" ];

        # Resource limits - 7d peak (130M) × 2.5 = 325M, using 512M for transcoding headroom
        resources = {
          memory = "512M";
          memoryReservation = "256M";
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

      # Homepage dashboard contribution
      modules.services.homepage.contributions.tdarr = {
        group = "Media";
        name = "Tdarr";
        icon = "tdarr";
        href = "https://tdarr.holthome.net";
        description = "Transcoding";
        siteMonitor = "http://localhost:8265";
        widget = {
          type = "tdarr";
          url = "http://localhost:8265";
          # API key optional - not configured
        };
      };
    })
  ];
}
