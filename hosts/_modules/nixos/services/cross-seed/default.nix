{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.cross-seed;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  crossSeedPort = 2468;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-cross-seed.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/cross-seed";

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

  # Generate config.js from Nix attributes
  baseConfig = {
    delay = 30;
    torrentDir = "/torrents";
    outputDir = "/output";
    includeEpisodes = true;
    includeSingleEpisodes = true;
    includeNonVideos = false;
    duplicateCategories = true;
    linkCategory = "cross-seed";
    linkDir = "/output";
    dataDirs = [ "/data" ];
    maxDataDepth = 3;
    torznab = [];
    port = crossSeedPort;
  };

  mergedConfig = baseConfig // cfg.extraSettings;

  # Convert Nix attrs to JavaScript object notation
  toJS = val:
    if builtins.isAttrs val then
      let
        pairs = lib.mapAttrsToList (k: v: "${lib.escapeShellArg k}: ${toJS v}") val;
      in "{ ${lib.concatStringsSep ", " pairs} }"
    else if builtins.isList val then
      "[ ${lib.concatMapStringsSep ", " toJS val} ]"
    else if builtins.isString val then
      lib.escapeShellArg val
    else if builtins.isBool val then
      if val then "true" else "false"
    else if builtins.isInt val || builtins.isFloat val then
      toString val
    else
      "null";

  configJs = pkgs.writeText "config.js" ''
    module.exports = ${toJS mergedConfig};
  '';
in
{
  options.modules.services.cross-seed = {
    enable = lib.mkEnableOption "cross-seed";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/cross-seed";
      description = "Path to cross-seed data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "921";
      description = "User account under which cross-seed runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which cross-seed runs.";
    };

    qbittorrentDataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qbittorrent";
      description = "Path to qBittorrent data directory (for BT_backup mount)";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/cross-seed/cross-seed:6.13.6@sha256:e2bf5b593e4e7d699e6242423ad7966190cd52ba8eefafdfdbb0cb5b0b609b96";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Use Renovate bot to automate version updates
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = ''
        Additional settings to merge into config.js.

        Example:
        {
          delay = 30;
          qbittorrentUrl = "http://127.0.0.1:8080";
          torznab = [ "http://prowlarr:9696/1/api?apikey=..." ];
        }
      '';
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
        default = "60s";
        description = "Grace period for container initialization.";
      };
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for cross-seed web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 2468;
        path = "/metrics";
        labels = {
          service_type = "media_automation";
          exporter = "cross-seed";
          function = "cross_seeding";
        };
      };
      description = "Prometheus metrics collection configuration (native /metrics endpoint)";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-cross-seed.service";
        labels = {
          service = "cross-seed";
          service_type = "media_tools";
        };
      };
      description = "Logging configuration for cross-seed";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "cross-seed" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/cross-seed";
      };
      description = "Backup configuration for cross-seed";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "cross-seed automatic cross-seeding failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for cross-seed service events";
    };

    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for cross-seed data directory";
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
      assertions =
        (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "cross-seed preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "cross-seed preseed.enable requires preseed.passwordFile to be set.";
        });

      users.groups.${cfg.group} = lib.mkIf (cfg.group == "media") {
        gid = 993;
      };

      users.users.cross-seed = {
        isSystemUser = true;
        uid = lib.toInt cfg.user;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = false;
        description = "cross-seed automatic cross-seeding daemon";
      };

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.cross-seed = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = crossSeedPort;
        };

        auth = cfg.reverseProxy.auth;
        authelia = cfg.reverseProxy.authelia;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Register with Authelia if SSO protection is enabled
      modules.services.authelia.accessControl.declarativelyProtectedServices.cross-seed = lib.mkIf (
        config.modules.services.authelia.enable &&
        cfg.reverseProxy != null &&
        cfg.reverseProxy.enable &&
        cfg.reverseProxy.authelia != null &&
        cfg.reverseProxy.authelia.enable
      ) (
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
            ++ authCfg.bypassResources;
        }
      );

      # Configuration file generation service
      systemd.services."cross-seed-config" = {
        description = "Generate cross-seed configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ mainServiceUnit ];
        script = ''
          mkdir -p ${cfg.dataDir}/config
          cp ${configJs} ${cfg.dataDir}/config/config.js
          chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/config
          chmod 0640 ${cfg.dataDir}/config/config.js
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };

      # Container service
      virtualisation.oci-containers.containers.cross-seed = {
        image = cfg.image;
        autoStart = true;
        user = "${cfg.user}:${toString config.users.groups.${cfg.group}.gid}";
        environment = {
          PUID = cfg.user;
          PGID = toString config.users.groups.${cfg.group}.gid;
          TZ = cfg.timezone;
        };
        volumes = [
          "${cfg.dataDir}/config:/config:rw"
          "${cfg.dataDir}/data:/data:rw"
          "${cfg.dataDir}/output:/output:rw"
          "${cfg.qbittorrentDataDir}/data/BT_backup:/torrents:ro"
        ];
        ports = [
          "127.0.0.1:${toString crossSeedPort}:${toString crossSeedPort}"
        ];
        extraOptions = [
          "--pull=never"
        ] ++ lib.optionals cfg.healthcheck.enable [
          "--health-cmd=curl -f http://localhost:${toString crossSeedPort}/api/healthz || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      systemd.services.${mainServiceUnit} = {
        after = [ "cross-seed-config.service" ];
        requires = [ "cross-seed-config.service" ];
      };

    })

    # Preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "cross-seed";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "lz4";
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
