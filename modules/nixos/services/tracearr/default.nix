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
# Uses the "supervised" all-in-one image which bundles TimescaleDB + Redis + App
# Secrets are auto-generated on first run and persisted.

{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

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
in
{
  options.modules.services.tracearr = {
    enable = lib.mkEnableOption "Tracearr - account sharing detection for media servers";

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/connorgallopo/tracearr:supervised";
      description = ''
        Tracearr container image. The "supervised" tag bundles TimescaleDB, Redis,
        and the Tracearr application in a single container.

        Pin to a specific digest for reproducibility:
        "ghcr.io/connorgallopo/tracearr:supervised@sha256:..."
      '';
      example = "ghcr.io/connorgallopo/tracearr:supervised@sha256:5527e61653fe98e690608546138244ab6ac19436f3c09f815d09826b428194cd";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tracearr";
      description = "Path to Tracearr data directory (stores TimescaleDB, Redis, and app data)";
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
      default = 937;
      description = "UID for the Tracearr service user";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "tracearr";
      description = "Group under which Tracearr runs";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 937;
      description = "GID for the Tracearr service group";
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

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1G"; # TimescaleDB + Redis + App need more memory
        memoryReservation = "512M";
        cpus = "2.0";
      };
      description = "Resource limits for the container (includes embedded TimescaleDB and Redis)";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "120s"; # TimescaleDB needs time to initialize
        onFailure = "kill";
      };
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
        tags = lib.mkDefault [ "media" "tracearr" "monitoring" "timescaledb" ];
        # Enable ZFS snapshots for database consistency
        useSnapshots = lib.mkDefault true;
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

      # Declare dataset requirements for per-service ZFS isolation
      modules.storage.datasets.services.tracearr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for PostgreSQL/TimescaleDB
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = toString cfg.uid;
        group = toString cfg.gid;
        mode = "0750";
      };

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

      # Tracearr container configuration (supervised all-in-one)
      virtualisation.oci-containers.containers.tracearr = podmanLib.mkContainer "tracearr" {
        image = cfg.image;
        environment = {
          TZ = cfg.timezone;
          LOG_LEVEL = cfg.logLevel;
          # Port is fixed at 3000 inside container, mapped externally
        };
        # Build environment file with optional MaxMind key
        environmentFiles = lib.optional (cfg.maxmindLicenseKeyFile != null) "/run/tracearr/env";
        volumes = [
          # The supervised image stores everything under /data
          "${cfg.dataDir}:/data:rw"
        ];
        ports = [
          "127.0.0.1:${toString tracearrPort}:3000"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=curl -f http://127.0.0.1:3000/api/health || exit 1''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Create environment file with MaxMind license key if provided
      systemd.services."${config.virtualisation.oci-containers.backend}-tracearr" = lib.mkMerge [
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
