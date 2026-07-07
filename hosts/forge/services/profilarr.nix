{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.profilarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.profilarr = {
        # FIXME (2026-05-11): Disabled - upstream image location changed.
        # The original ghcr.io/profilarr/profilarr container registry returns 403
        # Forbidden as of May 2026. The project moved to Dictionarry-Hub/profilarr.
        # UPDATE (2026-07-07): the new location now publishes public images
        # (2.0.x series); `image` below points at it, version+digest pinned so
        # Renovate keeps it current. Left disabled pending an operator decision:
        #   - The container's data directory at /var/lib/profilarr/ is empty -
        #     this service has never produced output on this host (recyclarr
        #     has been doing the equivalent TRaSH-guides sync work).
        #   - 2.x is a major rework vs. the 1.x this config targeted; verify the
        #     config/volume layout before enabling.
        # Tracked in docs/workarounds.md.
        enable = false;
        image = "ghcr.io/dictionarry-hub/profilarr:2.0.9@sha256:7a9b5112ff227320d17c65ab643a5d875713e6235991ef04a8e482ec51427902";
        podmanNetwork = forgeDefaults.podmanNetwork; # Enable DNS resolution to *arr services

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
