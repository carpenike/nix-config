# modules/nixos/services/readarr/default.nix
#
# Readarr - Book/audiobook collection manager
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

  name = "readarr";
  description = "Book and audiobook collection manager";

  spec = {
    # Core service configuration
    port = 8787;
    image = "ghcr.io/home-operations/readarr:latest";
    category = "media";
    displayName = "Readarr";
    function = "books";

    # Health check - Readarr has /ping endpoint
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
      READARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # Additional volumes - unified media mount
    volumes = cfg: [
      "${cfg.mediaDir}:/data:rw"
    ];
  };

  # Extra config: SOPS template for API key (referenced from host's secrets.nix)
  extraConfig = _cfg: {
    virtualisation.oci-containers.containers.readarr.environmentFiles = [
      config.sops.templates."readarr-env".path
    ];
  };
}
