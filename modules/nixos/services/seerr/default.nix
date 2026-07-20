# modules/nixos/services/seerr/default.nix
#
# Seerr - request management for Plex/Jellyfin/Emby
# (rebranded/merged successor to Overseerr and Jellyseerr)
#
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "seerr";
  description = "Seerr";

  spec = {
    # Core service configuration
    port = 5055;
    image = "ghcr.io/seerr-team/seerr:sha-adbcf80@sha256:2bfd7605fe24e3edbf704e893ac4b56a40a068facd30d2d0a524b915277a10f6";
    operationalProfile = "media";
    displayName = "Seerr";
    function = "request_management";

    # Health check - use /login instead of /api/v1/status; the status API tries
    # to reach external services (Plex, Sonarr, etc.) and times out if they're
    # unreachable.
    healthCommand = "wget --no-verbose --tries=1 --spider http://localhost:5055/login || exit 1";
    startPeriod = "60s";

    # ZFS tuning - 16K recordsize is optimal for Seerr's SQLite database
    zfsRecordSize = "16K";

    # Resource limits. Note: 512MB may be insufficient for large libraries
    # (50K+ items) - monitor and scale to 1-2GB if OOM kills are observed.
    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "1.0";
    };

    # Official seerr image expects config at /app/config (not /config) and
    # ships no init process (--init required).
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/app/config:rw"
    ];
    extraOptions = _: [ "--init" ];

    environment = _: {
      LOG_LEVEL = "info";
    };
  };

  extraOptions = {
    # Seerr has no native Prometheus metrics endpoint - keep metrics opt-in
    # (overrides the factory default of enabled).
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration for Seerr (no native metrics support)";
    };

    dependsOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of service names that Seerr depends on (e.g., "sonarr", "radarr").

        This ensures Seerr starts after its dependencies are ready, preventing
        connection errors and log spam during startup. Service names should match
        the base service name without the "podman-" prefix or ".service" suffix.
      '';
      example = [ "sonarr" "radarr" ];
    };
  };

  extraConfig = cfg: {
    # Legacy seerr group (pre-factory module always created it; the factory
    # only creates a group when cfg.group == service name, and Seerr runs
    # under the shared "media" group).
    users.groups.seerr = {
      gid = lib.mkDefault (lib.toInt cfg.user);
    };

    # Start after declared dependencies (sonarr/radarr) to avoid connection
    # errors during startup.
    systemd.services."${config.virtualisation.oci-containers.backend}-seerr" = {
      requires = map (s: "${config.virtualisation.oci-containers.backend}-${s}.service") cfg.dependsOn;
      after = map (s: "${config.virtualisation.oci-containers.backend}-${s}.service") cfg.dependsOn;
      serviceConfig.RestartSec = "10s";
    };

    # Backup integration using the standardized restic job pattern
    modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      seerr = {
        enable = true;
        paths = [ cfg.dataDir ];
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency;
        tags = cfg.backup.tags;
        excludePatterns = cfg.backup.excludePatterns;
        useSnapshots = cfg.backup.useSnapshots;
        zfsDataset = cfg.backup.zfsDataset;
      };
    };
  };
}
