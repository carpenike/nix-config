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
  serviceIds = mylib.serviceUids.bazarr;

  cfg = config.modules.services.bazarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  bazarrPort = 6767;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-bazarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/bazarr";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.bazarr = {
    enable = lib.mkEnableOption "Bazarr subtitle manager";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/bazarr";
      description = "Path to Bazarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = toString serviceIds.uid;
      description = "User account under which Bazarr runs (from lib/service-uids.nix).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which Bazarr runs.";
    };

    tvDir = lib.mkOption {
      type = lib.types.path;
      description = "Path to the TV series library (must match Sonarr's path).";
    };

    moviesDir = lib.mkOption {
      type = lib.types.path;
      description = "Path to the movie library (must match Radarr's path).";
    };

    dependencies = {
      sonarr = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Sonarr integration";
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL for the Sonarr API.";
              example = "http://localhost:8989";
            };
            # apiKeyFile is no longer needed; the key is injected via environmentFiles
          };
        };
        default = { enable = false; };
        description = "Configuration for connecting to Sonarr.";
      };
      radarr = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Radarr integration";
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL for the Radarr API.";
              example = "http://localhost:7878";
            };
            # apiKeyFile is no longer needed; the key is injected via environmentFiles
          };
        };
        default = { enable = false; };
        description = "Configuration for connecting to Radarr.";
      };
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach this container to.
        Enables DNS resolution to other containers on the same network.
        Network must be defined in `modules.virtualization.podman.networks`.
      '';
      example = "media-services";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/home-operations/bazarr:latest";
      description = "Full container image name for Bazarr.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "256M";
        memoryReservation = "128M";
        cpus = "1.0";
      };
      description = "Resource limits for the container";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "300s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Bazarr web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = false; # Bazarr does not have a native Prometheus endpoint
      };
      description = "Prometheus metrics collection configuration for Bazarr";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-bazarr.service";
        labels = {
          service = "bazarr";
          service_type = "media_utility";
        };
      };
      description = "Log shipping configuration for Bazarr logs";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "bazarr" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/bazarr";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/cache/**"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Bazarr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Bazarr subtitle manager failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Bazarr service events";
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
        description = "Order and selection of restore methods to attempt.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.tvDir != null && cfg.moviesDir != null;
          message = "Bazarr requires both tvDir and moviesDir to be set.";
        }
      ]
      ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
        assertion = cfg.backup.repository != null;
        message = "Bazarr backup.enable requires backup.repository to be set.";
      })
      ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.repositoryUrl != "";
        message = "Bazarr preseed.enable requires preseed.repositoryUrl to be set.";
      })
      ++ (lib.optional cfg.preseed.enable {
        assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
        message = "Bazarr preseed.enable requires preseed.passwordFile to be set.";
      });

      modules.services.caddy.virtualHosts.bazarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = bazarrPort;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      modules.storage.datasets.services.bazarr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user; # Use configured user
        group = cfg.group; # Use configured group
        mode = "0750";
      };

      users.users.bazarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group; # Use configured group (defaults to "media")
        isSystemUser = true;
        description = "Bazarr service user";
      };

      # Group is expected to be pre-defined (e.g., media group with GID 65537)
      # users.groups.bazarr removed - use shared media group instead

      virtualisation.oci-containers.containers.bazarr = podmanLib.mkContainer "bazarr" {
        image = cfg.image;
        environment =
          (lib.optionalAttrs cfg.dependencies.sonarr.enable {
            SONARR_URL = cfg.dependencies.sonarr.url;
          }) // (lib.optionalAttrs cfg.dependencies.radarr.enable {
            RADARR_URL = cfg.dependencies.radarr.url;
          }) // {
            PUID = cfg.user;
            PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
            TZ = cfg.timezone;
          };
        environmentFiles = [
          # API keys are injected via a templated environment file
          # to avoid evaluation-time errors with builtins.readFile
          config.sops.templates."bazarr-env".path
        ];
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.tvDir}:/tv:rw"
          "${cfg.moviesDir}:/movies:rw"
        ];
        ports = [
          "${toString bazarrPort}:6767"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:6767/)" = 200 ]' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          # When unhealthy, take configured action (default: kill so systemd can restart)
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          "--network=${cfg.podmanNetwork}"
        ];
      };

      systemd.services."${config.virtualisation.oci-containers.backend}-bazarr" = lib.mkMerge [
        # Add Podman network dependency if configured
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@bazarr-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-bazarr.service" ];
          after = [ "preseed-bazarr.service" ];
        })
        (lib.mkIf cfg.dependencies.sonarr.enable {
          wants = [ "podman-sonarr.service" ];
          after = [ "podman-sonarr.service" ];
        })
        (lib.mkIf cfg.dependencies.radarr.enable {
          wants = [ "podman-radarr.service" ];
          after = [ "podman-radarr.service" ];
        })
      ];

      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "bazarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Bazarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>
            The Bazarr service has entered a failed state.
          '';
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "bazarr";
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
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
