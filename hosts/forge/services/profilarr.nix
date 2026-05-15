{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.profilarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.profilarr = {
        # FIXME (2026-05-11): Disabled - upstream image is gone.
        # The original ghcr.io/profilarr/profilarr container registry returns 403
        # Forbidden as of May 2026. The project moved to Dictionarry-Hub/profilarr
        # but no public container image is published yet at the new location
        # (https://github.com/orgs/Dictionarry-Hub/packages?repo_name=profilarr
        # shows "No packages published"). The README documents `ghcr.io/dictionarry-hub/
        # profilarr:latest` but the image is not actually pushed there.
        #
        # Notes for re-enabling:
        #   1. Verify the new image is publicly pullable (check the org packages page).
        #   2. Update `image` to the new ref + digest (Renovate will keep it pinned).
        #   3. The container's data directory at /var/lib/profilarr/ is empty -
        #      this service has never produced output on this host (recyclarr
        #      has been doing the equivalent TRaSH-guides sync work).
        # Tracked in docs/workarounds.md.
        enable = false;
        image = "ghcr.io/profilarr/profilarr:latest";
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
