# modules/nixos/services/radarr/default.nix
#
# Radarr - Movie collection manager
# Factory-based implementation: ~80 lines vs 410 lines (80% reduction)
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

  name = "radarr";
  description = "Movie collection manager";

  spec = {
    # Core service configuration
    port = 7878;
    image = "ghcr.io/home-operations/radarr:latest";
    category = "media";
    displayName = "Radarr";
    function = "movies";

    # Health check - Radarr has /ping endpoint
    healthEndpoint = "/ping";
    startPeriod = "300s"; # Longer startup for media indexing

    # ZFS tuning for SQLite database
    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    # Metrics endpoint
    metricsPath = "/api/v3/health";

    # Resource limits
    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "2.0";
    };

    # Environment - external auth when behind authenticated proxy
    environment = { usesExternalAuth, ... }: {
      RADARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # Additional volumes - unified media mount (TRaSH Guides best practice)
    volumes = cfg: [
      "${cfg.mediaDir}:/data:rw"
    ];
  };

  # Extra config: SOPS template for API key (referenced from host's secrets.nix)
  extraConfig = _cfg: {
    virtualisation.oci-containers.containers.radarr.environmentFiles = [
      config.sops.templates."radarr-env".path
    ];
  };
}
