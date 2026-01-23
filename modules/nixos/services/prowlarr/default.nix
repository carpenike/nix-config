# modules/nixos/services/prowlarr/default.nix
#
# Prowlarr - Indexer manager for *arr services
# Factory-based implementation: ~70 lines vs 370 lines (81% reduction)
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "prowlarr";
  description = "Indexer manager for *arr services";

  spec = {
    # Core service configuration
    port = 9696;
    image = "ghcr.io/home-operations/prowlarr:latest";
    category = "media";
    displayName = "Prowlarr";
    function = "indexer_management";

    # Health check - Prowlarr has /ping endpoint
    healthEndpoint = "/ping";
    startPeriod = "120s";

    # ZFS tuning for SQLite database
    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    # Metrics endpoint
    metricsPath = "/api/v1/health";

    # Resource limits - lighter than Sonarr/Radarr
    resources = {
      memory = "256M";
      memoryReservation = "128M";
      cpus = "1.0";
    };

    # Environment - external auth when behind authenticated proxy
    environment = { usesExternalAuth, ... }: {
      PROWLARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # NOTE: Prowlarr doesn't need media directory mount - it's just an indexer manager
    # The factory will handle the NFS mount options but they won't be used unless
    # nfsMountDependency is explicitly set at the host level
  };

  # Extra config: SOPS template for API key (referenced from host's secrets.nix)
  extraConfig = _cfg: {
    virtualisation.oci-containers.containers.prowlarr.environmentFiles = [
      config.sops.templates."prowlarr-env".path
    ];
  };
}
