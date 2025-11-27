{ lib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.readarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  readarrPort = 8787;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-readarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/readarr";
  usesExternalAuth =
    cfg.reverseProxy != null
    && cfg.reverseProxy.enable
    && (
      (cfg.reverseProxy.authelia != null && cfg.reverseProxy.authelia.enable)
      || (cfg.reverseProxy.caddySecurity != null && cfg.reverseProxy.caddySecurity.enable)
    );

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig =
    if nfsMountName != null
    then config.modules.storage.nfsMounts.${nfsMountName} or null
    else null;

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
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
  options.modules.services.readarr = {
    enable = lib.mkEnableOption "Readarr book/audiobook collection manager";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/readarr";
      description = "Path to Readarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "911"; # Default linuxserver.io PUID
      description = "User ID to own the data directory (readarr:readarr in container)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "911"; # Default linuxserver.io PGID
      description = "Group ID to own the data directory";
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/books"; # Kept for standalone use, but will be overridden
      description = "Path to book library. Set automatically by nfsMountDependency.";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for media.
        This will automatically set `mediaDir` and systemd dependencies.
      '';
      example = "books";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/home-operations/readarr:latest";
      description = "Full container image name for Readarr.";
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
      description = "Reverse proxy configuration for Readarr web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = readarrPort;
        path = "/metrics";
        labels = {
          service_type = "media_management";
          exporter = "readarr";
          function = "books";
        };
      };
      description = "Prometheus metrics collection configuration for Readarr";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-readarr.service";
        labels = {
          service = "readarr";
          service_type = "media_management";
        };
      };
      description = "Log shipping configuration for Readarr logs";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "readarr" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/readarr";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/cache/**"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Readarr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Readarr book management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Readarr service events";
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
          message = "Readarr nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Readarr backup.enable requires backup.repository to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Readarr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Readarr preseed.enable requires preseed.passwordFile to be set.";
        });

      modules.services.readarr.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      modules.services.caddy.virtualHosts.readarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = readarrPort;
        };
        auth = cfg.reverseProxy.auth;
        authelia = cfg.reverseProxy.authelia;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      modules.services.authelia.accessControl.declarativelyProtectedServices.readarr = lib.mkIf
        (
          config.modules.services.authelia.enable &&
          cfg.reverseProxy != null &&
          cfg.reverseProxy.enable &&
          cfg.reverseProxy.authelia != null &&
          cfg.reverseProxy.authelia.enable
        )
        (
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

      modules.storage.datasets.services.readarr = {
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

      users.users.readarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group;
        isSystemUser = true;
        description = "Readarr service user";
        extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
      };

      users.groups.readarr = {
        gid = lib.mkDefault (lib.toInt cfg.group);
      };

      virtualisation.oci-containers.containers.readarr = podmanLib.mkContainer "readarr" {
        image = cfg.image;
        environment = {
          PUID = cfg.user;
          PGID = cfg.group;
          TZ = cfg.timezone;
          UMASK = "002";
          READARR__AUTHENTICATIONMETHOD = if usesExternalAuth then "External" else "None";
        };
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.mediaDir}:/books:rw" # Readarr expects /books
        ];
        ports = [
          "${toString readarrPort}:8787"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--umask=0027"
          "--pull=newer"
          "--user=${cfg.user}:${cfg.group}"
        ] ++ lib.optionals (nfsMountConfig != null) [
          "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8787/ping)" = 200 ]' ''
          "--health-interval=0s"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      systemd.services."${config.virtualisation.oci-containers.backend}-readarr" = lib.mkMerge [
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ nfsMountConfig.mountUnitName ];
          after = [ nfsMountConfig.mountUnitName ];
        })
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@readarr-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-readarr.service" ];
          after = [ "preseed-readarr.service" ];
        })
      ];

      systemd.timers.readarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Readarr Container Health Check Timer";
        wantedBy = [ "timers.target" ];
        after = [ mainServiceUnit ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.readarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Readarr Health Check";
        after = [ mainServiceUnit ];
        requires = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "readarr-healthcheck" ''
            set -euo pipefail
            if ! ${pkgs.podman}/bin/podman inspect readarr --format '{{.State.Running}}' | grep -q true; then
              echo "Container readarr is not running, skipping health check."
              exit 1
            fi
            if ${pkgs.podman}/bin/podman healthcheck run readarr; then
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
        "readarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Readarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>
            The Readarr service has entered a failed state.
          '';
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "readarr";
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
