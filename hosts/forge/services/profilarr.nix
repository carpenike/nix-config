{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.profilarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.profilarr = {
        # Profilarr - Profile sync for *arr services
        enable = true;
        image = "ghcr.io/profilarr/profilarr:latest";
        podmanNetwork = forgeDefaults.podmanNetwork;  # Enable DNS resolution to *arr services

        # Run daily at 3 AM to sync quality profiles
        schedule = "*-*-* 03:00:00";

        backup = forgeDefaults.mkBackupWithSnapshots "profilarr";
        notifications.enable = true;
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Note: profilarr runs as a scheduled timer, not a long-running service
        # Healthcheck is not applicable for oneshot timer-based services
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/profilarr" = forgeDefaults.mkSanoidDataset "profilarr";

      # Service availability alert
      modules.alerting.rules."profilarr-service-down" =
        forgeDefaults.mkServiceDownAlert "profilarr" "Profilarr" "profile sync";
    })
  ];
}
