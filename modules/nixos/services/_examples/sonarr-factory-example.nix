# Example: Sonarr using the service factory pattern
#
# This file demonstrates how the service factory reduces boilerplate.
# Compare this ~80 lines with the original ~450 lines in sonarr/default.nix
#
# DO NOT USE THIS FILE DIRECTLY - this is a reference example.
# The actual migration should be done incrementally after testing.

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
    containerPort = 8989; # Internal port if different
    image = "lscr.io/linuxserver/sonarr:latest";
    category = "media";
    function = "tv_series";
    displayName = "Sonarr";

    # Health check endpoint
    healthEndpoint = "/ping";
    startPeriod = "300s"; # Longer startup for media indexing

    # Resource limits
    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "2.0";
    };

    # ZFS dataset tuning for SQLite
    zfsRecordsize = "16K";
    zfsCompression = "zstd";

    # Metrics endpoint (Sonarr has /api/v3/health)
    metricsPath = "/api/v3/health";

    # Environment variables (function receives cfg and config)
    environment = { cfg, usesExternalAuth, ... }: {
      SONARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
    };

    # Additional volumes beyond dataDir
    volumes = cfg: [
      "${cfg.mediaDir}:/data:rw"
    ];

    # Additional container options
    extraOptions = { cfg, config }: [ ];
  };

  # Service-specific options beyond the standard set
  extraOptions = {
    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing pre-generated API key";
    };
  };

  # Service-specific config beyond the standard set
  extraConfig = cfg: {
    # SOPS template for API key
    sops.templates."sonarr-env" = lib.mkIf (cfg.apiKeyFile != null) {
      content = ''
        SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr/api_key"}
      '';
      owner = cfg.user;
    };

    # Add environment file to container
    virtualisation.oci-containers.containers.sonarr.environmentFiles = lib.mkIf (cfg.apiKeyFile != null) [
      config.sops.templates."sonarr-env".path
    ];
  };
}
