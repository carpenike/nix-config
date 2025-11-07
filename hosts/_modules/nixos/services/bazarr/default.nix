{
  lib,
  pkgs,
  config,
  podmanLib,
  ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.bazarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  bazarrPort = 6767;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-bazarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/bazarr";

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
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
      default = "914";
      description = "User account under which Bazarr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "993"; # shared media group
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

    healthcheck = {
      enable = lib.mkEnableOption "container health check";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Frequency of health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for each health check.";
      };
      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy.";
      };
      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "300s";
        description = "Grace period for the container to initialize before failures are counted.";
      };
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
        authelia = cfg.reverseProxy.authelia;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      modules.services.authelia.accessControl.declarativelyProtectedServices.bazarr = lib.mkIf (
        config.modules.services.authelia.enable &&
        cfg.reverseProxy != null &&
        cfg.reverseProxy.enable &&
        cfg.reverseProxy.authelia != null &&
        cfg.reverseProxy.authelia.enable
      ) (
        let
          authCfg = cfg.reverseProxy.authelia;
        in
        {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
            ++ authCfg.bypassResources;
        }
      );

      modules.storage.datasets.services.bazarr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = "bazarr";
        group = "bazarr";
        mode = "0750";
      };

      users.users.bazarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = "bazarr";
        isSystemUser = true;
        description = "Bazarr service user";
      };

      users.groups.bazarr = {
        gid = lib.mkDefault (lib.toInt cfg.group);
      };

      virtualisation.oci-containers.containers.bazarr = podmanLib.mkContainer "bazarr" {
        image = cfg.image;
        environment = (lib.mkIf cfg.dependencies.sonarr.enable {
          SONARR_URL = cfg.dependencies.sonarr.url;
        }) // (lib.mkIf cfg.dependencies.radarr.enable {
          RADARR_URL = cfg.dependencies.radarr.url;
        }) // {
          PUID = cfg.user;
          PGID = cfg.group;
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
          "--user=${cfg.user}:${cfg.group}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:6767/)" = 200 ]' ''
          "--health-interval=0s"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      systemd.services."${config.virtualisation.oci-containers.backend}-bazarr" = lib.mkMerge [
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

      systemd.timers.bazarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Bazarr Container Health Check Timer";
        wantedBy = [ "timers.target" ];
        after = [ mainServiceUnit ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.bazarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Bazarr Container Health Check";
        after = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "bazarr-healthcheck" ''
            set -euo pipefail
            if ! ${pkgs.podman}/bin/podman inspect bazarr --format '{{.State.Running}}' | grep -q true; then
              echo "Container bazarr is not running, skipping health check."
              exit 1
            fi
            if ${pkgs.podman}/bin/podman healthcheck run bazarr; then
              echo "Health check passed."
              exit 0
            else
              echo "Health check failed."
              exit 1
            fi
          '';
        };
      };

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
