# Unpackerr - Extracts downloads for Starr apps
#
# Unpackerr monitors download directories and extracts compressed archives (rar, zip, 7z)
# so Sonarr/Radarr can import media files. It polls arr apps for queued items and extracts
# archives as they complete downloading.
#
# Architecture:
# - No web UI or exposed ports (pure worker service)
# - Polls Sonarr/Radarr APIs at configurable intervals
# - Environment variable configuration via SOPS secrets
# - STATELESS: No persistent data to backup (all config from environment)
#
# Key Behaviors:
# - delete_orig = false for torrents (preserve for cross-seeding via qBittorrent)
# - delete_orig = true for usenet (SABnzbd - no seeding, safe to remove after extraction)
#
# Reference: https://unpackerr.zip/docs/
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  # Import shared type definitions (for containerResourcesSubmodule)
  sharedTypes = mylib.types;

  cfg = config.modules.services.unpackerr;
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-unpackerr.service";

  # Build environment variables for container
  # Unpackerr uses UN_ prefix for environment variables
  # See: https://unpackerr.zip/docs/install/configuration
  buildEnvVars =
    let
      # Global settings
      globalVars = {
        UN_DEBUG = lib.boolToString cfg.debug;
        UN_LOG_FILE = ""; # Log to stdout for container
        UN_LOG_FILES = "0"; # Disable log rotation (container stdout)
        UN_LOG_FILE_MB = "0";
        UN_QUIET = lib.boolToString cfg.quiet;
        UN_ACTIVITY = lib.boolToString cfg.activity;
        UN_START_DELAY = cfg.startDelay;
        UN_RETRY_DELAY = cfg.retryDelay;
        UN_MAX_RETRIES = toString cfg.maxRetries;
        UN_PARALLEL = toString cfg.parallel;
        UN_FILE_MODE = cfg.fileMode;
        UN_DIR_MODE = cfg.dirMode;
        TZ = cfg.timezone;
        PUID = toString cfg.user;
        PGID = toString cfg.group;
        # Enable metrics webserver for healthcheck
        UN_WEBSERVER_METRICS = "true";
        UN_WEBSERVER_LISTEN_ADDR = "0.0.0.0:${toString cfg.metricsPort}";
      };

      # Sonarr configuration (0-indexed for Unpackerr)
      sonarrVars = lib.optionalAttrs cfg.sonarr.enable {
        UN_SONARR_0_URL = cfg.sonarr.url;
        UN_SONARR_0_PATHS_0 = cfg.sonarr.path;
        UN_SONARR_0_PROTOCOLS = cfg.sonarr.protocols;
        UN_SONARR_0_TIMEOUT = cfg.sonarr.timeout;
        UN_SONARR_0_DELETE_ORIG = lib.boolToString cfg.sonarr.deleteOrig;
        UN_SONARR_0_DELETE_DELAY = cfg.sonarr.deleteDelay;
        UN_SONARR_0_SYNCTHING = "false";
      };

      # Radarr configuration
      radarrVars = lib.optionalAttrs cfg.radarr.enable {
        UN_RADARR_0_URL = cfg.radarr.url;
        UN_RADARR_0_PATHS_0 = cfg.radarr.path;
        UN_RADARR_0_PROTOCOLS = cfg.radarr.protocols;
        UN_RADARR_0_TIMEOUT = cfg.radarr.timeout;
        UN_RADARR_0_DELETE_ORIG = lib.boolToString cfg.radarr.deleteOrig;
        UN_RADARR_0_DELETE_DELAY = cfg.radarr.deleteDelay;
        UN_RADARR_0_SYNCTHING = "false";
      };
    in
    globalVars // sonarrVars // radarrVars;

in
{
  options.modules.services.unpackerr = {
    enable = lib.mkEnableOption "Unpackerr extraction service for Starr apps";

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/unpackerr/unpackerr:0.14.5@sha256:dc72256942ce50d1c8a1aeb5aa85b6ae2680a36eefd2182129d8d210fce78044";
      description = "Unpackerr container image with SHA256 digest";
    };

    user = lib.mkOption {
      type = lib.types.int;
      default = 917;
      description = "UID for Unpackerr (should match arr stack for file permissions)";
    };

    group = lib.mkOption {
      type = lib.types.int;
      default = 65537;
      description = "GID for Unpackerr (should match media group)";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "America/Los_Angeles";
      description = "Timezone for log timestamps";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data";
      description = "Media/downloads directory mount point (NFS or local)";
    };

    # NFS mount dependency
    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media";
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for media.
        When set, the service will depend on the NFS mount being available.
      '';
    };

    # Podman network
    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media-services";
      description = "Podman network to attach to (for service discovery)";
    };

    # Environment file for API keys (REQUIRED)
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/unpackerr/env";
      description = "Path to environment file containing API keys (from SOPS)";
    };

    # Resource limits (using shared types for consistency)
    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "128M";
        cpus = "1.0";
      };
      description = "Container resource limits";
    };

    # Metrics configuration (Prometheus endpoint)
    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 5656;
      description = "Port for Prometheus metrics endpoint (/metrics)";
    };

    # Healthcheck configuration
    # NOTE: Unpackerr uses a distroless container image with no shell or network tools.
    # In-container healthchecks are not possible. We rely on:
    # 1. Prometheus container_service_active metric for availability monitoring
    # 2. Prometheus scraping the /metrics endpoint for service health
    # Set enable=false since distroless container cannot run healthcheck commands.
    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = false; # Distroless container - no shell/wget available
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
      };
      description = "Container healthcheck configuration (disabled - distroless image has no tools)";
    };

    # Global settings
    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug logging";
    };

    quiet = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Quiet mode (less logging)";
    };

    activity = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable activity logging";
    };

    startDelay = lib.mkOption {
      type = lib.types.str;
      default = "1m";
      description = "Delay before starting to poll arr apps";
    };

    retryDelay = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "Delay between retries on failure";
    };

    maxRetries = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Maximum number of extraction retries";
    };

    parallel = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of parallel extractions";
    };

    fileMode = lib.mkOption {
      type = lib.types.str;
      default = "0644";
      description = "File permissions for extracted files";
    };

    dirMode = lib.mkOption {
      type = lib.types.str;
      default = "0755";
      description = "Directory permissions for extracted directories";
    };

    # Sonarr integration
    sonarr = {
      enable = lib.mkEnableOption "Sonarr integration";

      url = lib.mkOption {
        type = lib.types.str;
        default = "http://sonarr:8989";
        description = "Sonarr URL (container name or IP)";
      };

      path = lib.mkOption {
        type = lib.types.str;
        default = "/data/qb/downloads";
        description = "Download path to monitor for Sonarr content (inside container)";
      };

      protocols = lib.mkOption {
        type = lib.types.str;
        default = "torrent,usenet";
        description = "Protocols to monitor (torrent, usenet, or both)";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "API request timeout";
      };

      deleteOrig = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Delete original archive after extraction (false for torrents/cross-seeding)";
      };

      deleteDelay = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Delay before deleting original (if deleteOrig is true)";
      };
    };

    # Radarr integration
    radarr = {
      enable = lib.mkEnableOption "Radarr integration";

      url = lib.mkOption {
        type = lib.types.str;
        default = "http://radarr:7878";
        description = "Radarr URL (container name or IP)";
      };

      path = lib.mkOption {
        type = lib.types.str;
        default = "/data/qb/downloads";
        description = "Download path to monitor for Radarr content (inside container)";
      };

      protocols = lib.mkOption {
        type = lib.types.str;
        default = "torrent,usenet";
        description = "Protocols to monitor (torrent, usenet, or both)";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "API request timeout";
      };

      deleteOrig = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Delete original archive after extraction (false for torrents/cross-seeding)";
      };

      deleteDelay = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Delay before deleting original (if deleteOrig is true)";
      };
    };

    # Notification integration
    notifications = {
      enable = lib.mkEnableOption "failure notifications";
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertions
    assertions = [
      {
        assertion = cfg.sonarr.enable || cfg.radarr.enable;
        message = "Unpackerr requires at least one of sonarr or radarr integration to be enabled";
      }
      {
        assertion = cfg.environmentFile != null;
        message = "Unpackerr requires an environment file for API keys";
      }
    ];

    # Auto-configure mediaDir from NFS mount if specified
    modules.services.unpackerr.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

    # Podman container definition using podmanLib for consistent logging and resource limits
    virtualisation.oci-containers.containers.unpackerr = podmanLib.mkContainer "unpackerr" {
      image = cfg.image;
      autoStart = true;

      # Environment variables (non-secret settings)
      environment = buildEnvVars;

      # Environment file for API keys
      environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile;

      # Volume mounts - only media directory needed (stateless service)
      volumes = [
        "${cfg.mediaDir}:/data:rw" # Unified mount point matching other arr services
      ];

      # Resource limits (handled by podmanLib.mkContainer)
      resources = cfg.resources;

      # Network configuration and healthcheck
      extraOptions = lib.flatten [
        # Attach to podman network for service discovery
        (lib.optional (cfg.podmanNetwork != null) "--network=${cfg.podmanNetwork}")
        # Run as specific user/group
        "--user=${toString cfg.user}:${toString cfg.group}"
        # Healthcheck - probe the metrics endpoint
        (lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          "--health-cmd=wget -q --spider http://127.0.0.1:${toString cfg.metricsPort}/metrics || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ])
      ];
    };

    # Systemd service overrides
    systemd.services.${mainServiceUnit} = {
      # Wait for NFS mount
      after = lib.optionals (nfsMountConfig != null) [
        (if nfsMountConfig.autoMount or false
        then lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" nfsMountConfig.localPath) + ".automount"
        else lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" nfsMountConfig.localPath) + ".mount")
      ];
      requires = lib.optionals (nfsMountConfig != null && !(nfsMountConfig.autoMount or false)) [
        (lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" nfsMountConfig.localPath) + ".mount")
      ];

      # Notification integration for service failures
      unitConfig = lib.mkIf (cfg.notifications.enable && hasCentralizedNotifications) {
        OnFailure = [ "notify-service-failure@%n.service" ];
      };

      # Restart policy
      serviceConfig = {
        Restart = "always";
        RestartSec = "30s";
      };
    };
  };
}
