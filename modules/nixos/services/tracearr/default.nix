# modules/nixos/services/tracearr/default.nix
#
# Tracearr - Account sharing detection and monitoring for Plex, Jellyfin, and Emby
#
# Features:
# - Session tracking with IP geolocation
# - Sharing detection rules (impossible travel, simultaneous locations, etc.)
# - Trust scores and real-time alerts
# - Multi-server support (Plex, Jellyfin, Emby)
# - Stream map visualization
# - Tautulli/Jellystat history import
#
# Deployment Modes:
# - embedded (default): Uses "supervised" all-in-one image with bundled TimescaleDB + Redis
# - external: Uses standard image with external PostgreSQL (TimescaleDB) and Redis
#
# For external mode, set:
#   deploymentMode = "external";
#   database.host = "host.containers.internal";
#   database.passwordFile = <sops secret path>;
#   redis.url = "redis://host.containers.internal:6379/0";
#
# TimescaleDB extension MUST be enabled on the external PostgreSQL database.

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
  # Import shared type definitions
  sharedTypes = mylib.types;
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.tracearr;

  cfg = config.modules.services.tracearr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  tracearrPort = cfg.port;
  serviceName = "tracearr";
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Determine if using external databases
  useExternalDatabases = cfg.deploymentMode == "external";
in
{
  options.modules.services.tracearr = {
    enable = lib.mkEnableOption "Tracearr - account sharing detection for media servers";

    deploymentMode = lib.mkOption {
      type = lib.types.enum [ "embedded" "external" ];
      default = "embedded";
      description = ''
        Deployment mode for Tracearr:

        - embedded: Uses the "supervised" all-in-one image with bundled TimescaleDB and Redis.
          Simpler setup but less flexible. Recommended for testing or standalone deployments.

        - external: Uses the standard image with external PostgreSQL (with TimescaleDB extension)
          and Redis. Recommended for production when you have centralized database infrastructure.
          Requires database.host, database.passwordFile, and redis.url to be configured.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.deploymentMode == "external"
        then "ghcr.io/connorgallopo/tracearr:latest"
        else "ghcr.io/connorgallopo/tracearr:supervised";
      defaultText = lib.literalExpression ''
        if deploymentMode == "external"
        then "ghcr.io/connorgallopo/tracearr:latest"
        else "ghcr.io/connorgallopo/tracearr:supervised"
      '';
      description = ''
        Tracearr container image.

        For deploymentMode = "embedded": Use the "supervised" tag which bundles TimescaleDB, Redis,
        and the Tracearr application in a single container.

        For deploymentMode = "external": Use the "latest" tag (standard image) which connects
        to external PostgreSQL and Redis via DATABASE_URL and REDIS_URL environment variables.

        Pin to a specific digest for reproducibility.
      '';
      example = "ghcr.io/connorgallopo/tracearr:latest@sha256:...";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tracearr";
      description = ''
        Path to Tracearr data directory.

        For embedded mode: stores TimescaleDB, Redis, and app data.
        For external mode: stores only app data (GeoIP databases, secrets, etc.).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3004;
      description = "Port for the Tracearr web interface";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "tracearr";
      description = "User account under which Tracearr runs";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.uid;
      description = "UID for the Tracearr service user (from lib/service-uids.nix)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "tracearr";
      description = "Group under which Tracearr runs";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.gid;
      description = "GID for the Tracearr service group (from lib/service-uids.nix)";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    # MaxMind GeoIP integration for IP geolocation
    maxmindLicenseKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing MaxMind license key for GeoIP database updates.
        Enables more accurate IP geolocation for sharing detection.
        Get a free license key at: https://www.maxmind.com/en/geolite2/signup
      '';
      example = "config.sops.secrets.\"tracearr/maxmind_license_key\".path";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level for the Tracearr application";
    };

    # External database configuration (used when deploymentMode = "external")
    database = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "host.containers.internal";
        description = ''
          PostgreSQL host address for external database mode.
          Default uses Podman's host alias so containers can reach the host PostgreSQL.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "tracearr";
        description = "Database name (must have TimescaleDB extension enabled)";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "tracearr";
        description = "Database user";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing database password for external mode.
          Required when deploymentMode = "external".
        '';
      };

      manageDatabase = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to automatically provision the PostgreSQL database via
          modules.services.postgresql.databases when deploymentMode = "external".
          Set to false if managing the database manually.
        '';
      };
    };

    # Security secrets (required for external mode, auto-generated for embedded)
    secrets = {
      jwtSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing JWT secret for authentication (32 hex chars).
          Required when deploymentMode = "external".
          Generate with: openssl rand -hex 32
        '';
        example = "config.sops.secrets.\"tracearr/jwt_secret\".path";
      };

      cookieSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing cookie secret for sessions (32 hex chars).
          Required when deploymentMode = "external".
          Generate with: openssl rand -hex 32
        '';
        example = "config.sops.secrets.\"tracearr/cookie_secret\".path";
      };
    };

    redis = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Redis URL for external mode (e.g., "redis://host.containers.internal:6379/0").
          Required when deploymentMode = "external".
        '';
        example = "redis://host.containers.internal:6379/0";
      };
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = if cfg.deploymentMode == "external" then "512M" else "1G";
        memoryReservation = if cfg.deploymentMode == "external" then "256M" else "512M";
        cpus = if cfg.deploymentMode == "external" then "1.0" else "2.0";
      };
      defaultText = lib.literalExpression ''
        {
          # External mode uses less resources (no embedded databases)
          memory = if deploymentMode == "external" then "512M" else "1G";
          memoryReservation = if deploymentMode == "external" then "256M" else "512M";
          cpus = if deploymentMode == "external" then "1.0" else "2.0";
        }
      '';
      description = ''
        Resource limits for the container.
        External mode requires fewer resources since databases run separately.
      '';
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        # External mode starts faster (no database initialization)
        startPeriod = if cfg.deploymentMode == "external" then "30s" else "120s";
        onFailure = "kill";
      };
      defaultText = lib.literalExpression ''
        {
          enable = true;
          interval = "30s";
          timeout = "10s";
          retries = 3;
          startPeriod = if deploymentMode == "external" then "30s" else "120s";
          onFailure = "kill";
        }
      '';
      description = "Container healthcheck configuration";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Tracearr web interface";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault (
          if cfg.deploymentMode == "external"
          then [ "media" "tracearr" "monitoring" ]
          else [ "media" "tracearr" "monitoring" "timescaledb" ]
        );
        # Enable ZFS snapshots only for embedded mode (includes databases)
        useSnapshots = lib.mkDefault (cfg.deploymentMode == "embedded");
        zfsDataset = lib.mkDefault "tank/services/tracearr";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Tracearr";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Tracearr media monitoring failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Tracearr service events";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Assertions
      assertions = [
        {
          assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
          message = "Tracearr backup.enable requires backup.repository to be set.";
        }
        {
          assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
          message = "Tracearr preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.deploymentMode == "embedded" || cfg.database.passwordFile != null;
          message = "Tracearr external mode requires database.passwordFile to be set.";
        }
        {
          assertion = cfg.deploymentMode == "embedded" || cfg.redis.url != null;
          message = "Tracearr external mode requires redis.url to be set.";
        }
        {
          assertion = cfg.deploymentMode == "embedded" || cfg.secrets.jwtSecretFile != null;
          message = "Tracearr external mode requires secrets.jwtSecretFile to be set (generate with: openssl rand -hex 32).";
        }
        {
          assertion = cfg.deploymentMode == "embedded" || cfg.secrets.cookieSecretFile != null;
          message = "Tracearr external mode requires secrets.cookieSecretFile to be set (generate with: openssl rand -hex 32).";
        }
      ];

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.tracearr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = tracearrPort;
        };

        # Authentication - Tracearr uses Plex/Jellyfin SSO natively
        # No caddySecurity needed as users authenticate with their media server credentials
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Provision PostgreSQL database with TimescaleDB when using external mode
      modules.services.postgresql.databases.tracearr = lib.mkIf (useExternalDatabases && cfg.database.manageDatabase) {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        extensions = [ "timescaledb" ];
      };

      # Declare dataset requirements for per-service ZFS isolation
      modules.storage.datasets.services.tracearr = {
        mountpoint = cfg.dataDir;
        # Use smaller recordsize for external mode (less data stored locally)
        recordsize = if useExternalDatabases then "128K" else "16K";
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = toString cfg.uid;
        group = toString cfg.gid;
        mode = "0750";
      };

      # Create subdirectories based on deployment mode
      # Embedded mode: needs postgres, redis, tracearr subdirs for container VOLUMEs
      # External mode: only needs tracearr subdir for app data
      systemd.tmpfiles.rules =
        if useExternalDatabases then [
          "d ${cfg.dataDir}/tracearr 0750 ${toString cfg.uid} ${toString cfg.gid} -"
        ] else [
          # The supervised image declares VOLUME [/data/postgres /data/redis /data/tracearr]
          # Let container manage ownership internally (don't set explicit uid/gid)
          "d ${cfg.dataDir}/postgres 0750 - - -"
          "d ${cfg.dataDir}/redis 0750 - - -"
          "d ${cfg.dataDir}/tracearr 0750 - - -"
        ];

      # Create local users to match container expectations
      users.users.${cfg.user} = {
        uid = cfg.uid;
        group = cfg.group;
        isSystemUser = true;
        description = "Tracearr service user";
        home = "/var/empty";
        createHome = false;
      };

      users.groups.${cfg.group} = {
        gid = cfg.gid;
      };

      # Tracearr container configuration
      virtualisation.oci-containers.containers.tracearr = podmanLib.mkContainer "tracearr" {
        image = cfg.image;
        environment = {
          TZ = cfg.timezone;
          LOG_LEVEL = cfg.logLevel;
          # Port is fixed at 3000 inside container, mapped externally
        } // lib.optionalAttrs useExternalDatabases {
          # Redis URL can be passed directly (no secrets)
          REDIS_URL = cfg.redis.url;
          # DATABASE_URL is set via environment file to avoid exposing password in process list
        };
        # Build environment file with optional MaxMind key and database password
        environmentFiles =
          lib.optional (cfg.maxmindLicenseKeyFile != null) "/run/tracearr/env"
          ++ lib.optional useExternalDatabases "/run/tracearr/db-env";
        volumes =
          if useExternalDatabases then [
            # External mode: only mount app data directory
            "${cfg.dataDir}/tracearr:/data/tracearr:rw"
          ] else [
            # Embedded mode: mount all data directories for supervised image
            # The supervised image declares VOLUME for /data/postgres, /data/redis, /data/tracearr
            # which creates anonymous volumes that override a simple /data bind mount.
            # We must explicitly bind mount each subdirectory to ensure data persists to our ZFS dataset.
            "${cfg.dataDir}/postgres:/data/postgres:rw"
            "${cfg.dataDir}/redis:/data/redis:rw"
            "${cfg.dataDir}/tracearr:/data/tracearr:rw"
          ];
        ports = [
          "127.0.0.1:${toString tracearrPort}:3000"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Use /health endpoint which returns JSON status of db, redis, geoip, and timescale
          ''--health-cmd=curl -sf http://127.0.0.1:3000/health > /dev/null''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Create environment file with MaxMind license key if provided
      systemd.services."${config.virtualisation.oci-containers.backend}-tracearr" = lib.mkMerge [
        # Base configuration for external mode: load database and security credentials
        (lib.mkIf useExternalDatabases {
          serviceConfig.LoadCredential = lib.mkMerge [
            (lib.mkIf (cfg.database.passwordFile != null) [
              "db_password:${cfg.database.passwordFile}"
            ])
            (lib.mkIf (cfg.secrets.jwtSecretFile != null) [
              "jwt_secret:${cfg.secrets.jwtSecretFile}"
            ])
            (lib.mkIf (cfg.secrets.cookieSecretFile != null) [
              "cookie_secret:${cfg.secrets.cookieSecretFile}"
            ])
          ];
          preStart = lib.mkBefore ''
            install -d -m 700 /run/tracearr
            # Build environment file with DATABASE_URL, JWT_SECRET, and COOKIE_SECRET
            {
              ${lib.optionalString (cfg.database.passwordFile != null) ''
                # Generate DATABASE_URL with substituted password
                DB_PASS="$(cat "$CREDENTIALS_DIRECTORY/db_password")"
                printf "DATABASE_URL=postgresql://${cfg.database.user}:%s@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}\n" "$DB_PASS"
              ''}
              ${lib.optionalString (cfg.secrets.jwtSecretFile != null) ''
                JWT_SECRET="$(cat "$CREDENTIALS_DIRECTORY/jwt_secret")"
                printf "JWT_SECRET=%s\n" "$JWT_SECRET"
              ''}
              ${lib.optionalString (cfg.secrets.cookieSecretFile != null) ''
                COOKIE_SECRET="$(cat "$CREDENTIALS_DIRECTORY/cookie_secret")"
                printf "COOKIE_SECRET=%s\n" "$COOKIE_SECRET"
              ''}
            } > /run/tracearr/db-env
            chmod 600 /run/tracearr/db-env
          '';
        })
        # MaxMind GeoIP license key handling
        (lib.mkIf (cfg.maxmindLicenseKeyFile != null) {
          serviceConfig.LoadCredential = [
            "maxmind_license_key:${cfg.maxmindLicenseKeyFile}"
          ];
          preStart = ''
            install -d -m 700 /run/tracearr
            {
              printf "MAXMIND_LICENSE_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/maxmind_license_key")"
            } > /run/tracearr/env
            chmod 600 /run/tracearr/env
          '';
        })
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@tracearr-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-tracearr.service" ];
          after = [ "preseed-tracearr.service" ];
        })
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "tracearr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Tracearr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Tracearr media monitoring service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Add the preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "tracearr";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = toString cfg.uid;
        group = toString cfg.gid;
      }
    ))
  ];
}
