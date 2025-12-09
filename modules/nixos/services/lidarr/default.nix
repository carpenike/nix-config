{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

  cfg = config.modules.services.lidarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  lidarrPort = 8686;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-lidarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/lidarr";
  usesExternalAuth =
    cfg.reverseProxy != null
    && cfg.reverseProxy.enable
    && (cfg.reverseProxy.caddySecurity != null && cfg.reverseProxy.caddySecurity.enable);

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.lidarr = {
    enable = lib.mkEnableOption "Lidarr music collection manager";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/lidarr";
      description = "Path to Lidarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "911"; # Default linuxserver.io PUID
      description = "User ID to own the data directory (lidarr:lidarr in container)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "911"; # Default linuxserver.io PGID
      description = "Group ID to own the data directory";
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/music"; # Kept for standalone use, but will be overridden
      description = "Path to music library. Set automatically by nfsMountDependency.";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for media.
        This will automatically set `mediaDir` and systemd dependencies.
      '';
      example = "music";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/home-operations/lidarr:latest";
      description = "Full container image name for Lidarr.";
    };

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group with permissions to the media library, for NFS access.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "256M";
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
      description = "Reverse proxy configuration for Lidarr web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = lidarrPort;
        path = "/metrics";
        labels = {
          service_type = "media_management";
          exporter = "lidarr";
          function = "music";
        };
      };
      description = "Prometheus metrics collection configuration for Lidarr";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-lidarr.service";
        labels = {
          service = "lidarr";
          service_type = "media_management";
        };
      };
      description = "Log shipping configuration for Lidarr logs";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "lidarr" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/lidarr";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/cache/**"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Lidarr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Lidarr music management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Lidarr service events";
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
      assertions =
        (lib.optional (nfsMountName != null) {
          assertion = nfsMountConfig != null;
          message = "Lidarr nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Lidarr backup.enable requires backup.repository to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Lidarr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Lidarr preseed.enable requires preseed.passwordFile to be set.";
        });

      modules.services.lidarr.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      modules.services.caddy.virtualHosts.lidarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = lidarrPort;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      modules.storage.datasets.services.lidarr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      users.users.lidarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group;
        isSystemUser = true;
        description = "Lidarr service user";
        extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
      };

      users.groups.lidarr = {
        gid = lib.mkDefault (lib.toInt cfg.group);
      };

      virtualisation.oci-containers.containers.lidarr = podmanLib.mkContainer "lidarr" {
        image = cfg.image;
        environment = {
          PUID = cfg.user;
          PGID = cfg.group;
          TZ = cfg.timezone;
          UMASK = "002";
          LIDARR__AUTHENTICATIONMETHOD = if usesExternalAuth then "External" else "None";
        };
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.mediaDir}:/music:rw" # Lidarr expects /music
        ];
        ports = [
          "${toString lidarrPort}:8686"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--umask=0027"
          "--pull=newer"
          "--user=${cfg.user}:${cfg.group}"
        ] ++ lib.optionals (nfsMountConfig != null) [
          "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8686/ping)" = 200 ]' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          # When unhealthy, take configured action (default: kill so systemd can restart)
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      systemd.services."${config.virtualisation.oci-containers.backend}-lidarr" = lib.mkMerge [
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ nfsMountConfig.mountUnitName ];
          after = [ nfsMountConfig.mountUnitName ];
        })
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@lidarr-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-lidarr.service" ];
          after = [ "preseed-lidarr.service" ];
        })
      ];

      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "lidarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Lidarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>
            The Lidarr service has entered a failed state.
          '';
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "lidarr";
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
