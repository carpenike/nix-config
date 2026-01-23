# modules/nixos/services/sonarr/default.nix
#
# Sonarr - TV series collection manager
# Factory-based implementation: ~80 lines vs 458 lines (82% reduction)
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

  name = "sonarr";
  description = "TV series collection manager";

  spec = {
    # Core service configuration
    port = 8989;
    image = "ghcr.io/home-operations/sonarr:latest";
    category = "media";
    displayName = "Sonarr";
    function = "tv_series";

    # Health check - Sonarr has /ping endpoint
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
      SONARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # Additional volumes - unified media mount (TRaSH Guides best practice)
    volumes = cfg: [
      "${cfg.mediaDir}:/data:rw"
    ];
  };

  # Extra config: SOPS template for API key (referenced from host's secrets.nix)
  extraConfig = _cfg: {
    virtualisation.oci-containers.containers.sonarr.environmentFiles = [
      config.sops.templates."sonarr-env".path
    ];
  };
}
