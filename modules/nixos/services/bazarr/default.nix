# modules/nixos/services/bazarr/default.nix
#
# Bazarr - Subtitle manager for Sonarr/Radarr
# Factory-based implementation: ~95 lines vs 358 lines (73% reduction)
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

  name = "bazarr";
  description = "Subtitle manager for Sonarr/Radarr";

  spec = {
    # Core service configuration
    port = 6767;
    image = "ghcr.io/home-operations/bazarr:latest";
    category = "media";
    displayName = "Bazarr";
    function = "subtitles";

    # Health check
    healthEndpoint = "/";
    startPeriod = "120s";

    # ZFS tuning for SQLite database
    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    # Resource limits - lighter than Sonarr/Radarr
    resources = {
      memory = "256M";
      memoryReservation = "128M";
      cpus = "1.0";
    };

    # No external auth for Bazarr (configure in web UI)
    environment = _: { };

    # Additional volumes - TV and movie paths (must match Sonarr/Radarr)
    volumes = cfg: [
      "${cfg.tvDir}:/tv:rw"
      "${cfg.moviesDir}:/movies:rw"
    ];
  };

  # Service-specific options
  extraOptions = {
    tvDir = lib.mkOption {
      type = lib.types.path;
      description = "Path to the TV series library (must match Sonarr's path)";
    };

    moviesDir = lib.mkOption {
      type = lib.types.path;
      description = "Path to the movie library (must match Radarr's path)";
    };

    dependencies = {
      sonarr = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Sonarr integration";
          };
        };
        default = { enable = false; };
        description = "Enable systemd dependency on Sonarr (ensures Sonarr starts first)";
      };
      radarr = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Radarr integration";
          };
        };
        default = { enable = false; };
        description = "Enable systemd dependency on Radarr (ensures Radarr starts first)";
      };
    };
  };

  # Extra config: systemd dependencies on Sonarr/Radarr
  extraConfig = cfg: {
    systemd.services."${config.virtualisation.oci-containers.backend}-bazarr" = lib.mkMerge [
      (lib.mkIf cfg.dependencies.sonarr.enable {
        wants = [ "podman-sonarr.service" ];
        after = [ "podman-sonarr.service" ];
      })
      (lib.mkIf cfg.dependencies.radarr.enable {
        wants = [ "podman-radarr.service" ];
        after = [ "podman-radarr.service" ];
      })
    ];
    # NOTE: Bazarr doesn't auto-configure from environment variables
    # API keys for Sonarr/Radarr must be configured in the Bazarr web UI
  };
}
