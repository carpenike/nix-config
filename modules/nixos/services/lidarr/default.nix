# modules/nixos/services/lidarr/default.nix
#
# Lidarr - Music collection manager
# Factory-based implementation: ~70 lines vs 353 lines (80% reduction)
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

  name = "lidarr";
  description = "Music collection manager";

  spec = {
    # Core service configuration
    port = 8686;
    image = "ghcr.io/home-operations/lidarr:latest";
    category = "media";
    displayName = "Lidarr";
    function = "music";

    # Health check - Lidarr has /ping endpoint
    healthEndpoint = "/ping";
    startPeriod = "300s"; # Longer startup for media indexing

    # ZFS tuning for SQLite database
    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    # Metrics endpoint
    metricsPath = "/api/v1/health";

    # Resource limits
    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "1.0";
    };

    # Environment - external auth when behind authenticated proxy
    environment = { usesExternalAuth, ... }: {
      LIDARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # Additional volumes - unified media mount
    volumes = cfg: [
      "${cfg.mediaDir}:/data:rw"
    ];
  };

  # Extra config: SOPS template for API key (referenced from host's secrets.nix)
  extraConfig = _cfg: {
    virtualisation.oci-containers.containers.lidarr.environmentFiles = [
      config.sops.templates."lidarr-env".path
    ];
  };
}
