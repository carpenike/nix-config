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

  # Only cfg is needed at top level for mkIf condition
  cfg = config.modules.services.overseerr;
in
{
  options.modules.services.overseerr = {
    enable = lib.mkEnableOption "Overseerr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/overseerr";
      description = "Path to Overseerr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "917";
      description = "User account under which Overseerr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Overseerr runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/overseerr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability (e.g., "1.33.2@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "lscr.io/linuxserver/overseerr:1.33.2@sha256:f3ad4f59e6e5e4a...";
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
        default = "60s";
        description = "Grace period for container initialization before failures are counted.";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Overseerr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration for Overseerr (no native metrics support)";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Overseerr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Overseerr request management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Overseerr service events";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Overseerr data.

        Overseerr stores all configuration and user data in a SQLite database at /var/lib/overseerr.
        This includes request history, user settings, and integration configurations.

        Recommended recordsize: 16K (optimal for SQLite databases)
      '';
    };

    # Dataset configuration with storage helper integration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Overseerr data directory";
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
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds. Examples:
          - [ "syncoid" "local" "restic" ] - Default, try replication first
          - [ "local" "restic" ] - Skip replication, try local snapshots first
          - [ "restic" ] - Restic-only (for air-gapped systems)
          - [ "local" "restic" "syncoid" ] - Local-first for quick recovery
        '';
      };
    };
  };

  config = let
    # Move config-dependent variables here to avoid infinite recursion
    storageCfg = config.modules.storage;
    overseerrPort = 5055;
    mainServiceUnit = "${config.virtualisation.oci-containers.backend}-overseerr.service";
    datasetPath = "${storageCfg.datasets.parentDataset}/overseerr";

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

    hasCentralizedNotifications = config.modules.notifications.alertmanager.enable or false;
  in lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.reverseProxy != null -> cfg.reverseProxy.enable;
          message = "Overseerr reverse proxy must be explicitly enabled when configured";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
          message = "Overseerr preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
          message = "Overseerr preseed.enable requires preseed.passwordFile to be set.";
        }
        {
          assertion = cfg.backup != null -> cfg.backup.enable;
          message = "Overseerr backup must be explicitly enabled when configured";
        }
      ];

    # Warnings for missing critical configuration
    warnings =
      (lib.optional (cfg.reverseProxy == null) "Overseerr has no reverse proxy configured. Service will only be accessible locally.")
      ++ (lib.optional (cfg.backup == null) "Overseerr has no backup configured. User data and settings will not be protected.");

    # Create ZFS dataset for Overseerr data
    modules.storage.datasets.services.overseerr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for SQLite databases
      compression = "zstd";
      properties = {
        "com.sun:auto-snapshot" = "true";
      };
      owner = "overseerr";
      group = "overseerr";
      mode = "0750";
    };

    # Create system user for Overseerr
    users.users.overseerr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group;
      isSystemUser = true;
      description = "Overseerr service user";
    };

    # Create system group for Overseerr
    users.groups.overseerr = {
      gid = lib.mkDefault (lib.toInt cfg.user);
    };

    # Overseerr container configuration
    virtualisation.oci-containers.containers.overseerr = podmanLib.mkContainer "overseerr" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = toString config.users.groups.${cfg.group}.gid;
        TZ = cfg.timezone;
      };
      volumes = [
        "${cfg.dataDir}:/config:rw"
      ];
      ports = [ "${toString overseerrPort}:5055" ];
      log-driver = "journald";
      extraOptions =
        (lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--memory-reservation=${cfg.resources.memoryReservation}"
          "--cpus=${cfg.resources.cpus}"
        ])
        ++ (lib.optionals (cfg.healthcheck.enable) [
          "--health-cmd=curl --fail http://localhost:5055/api/v1/status || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ]);
    };

    # Systemd service dependencies and security
    systemd.services."${mainServiceUnit}" = {
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    # Integrate with centralized Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.overseerr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = overseerrPort;
      };
      auth = cfg.reverseProxy.auth;
      authelia = cfg.reverseProxy.authelia;
      security = cfg.reverseProxy.security;
      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Register with Authelia for SSO protection
    modules.services.authelia.accessControl.declarativelyProtectedServices.overseerr = lib.mkIf (
      cfg.reverseProxy != null && cfg.reverseProxy.enable && cfg.reverseProxy.authelia.enable
    ) {
      domain = cfg.reverseProxy.hostName;
      policy = cfg.reverseProxy.authelia.policy;
      subject = map (group: "group:${group}") cfg.reverseProxy.authelia.allowedGroups;
      bypassResources = map (path: "^${lib.escapeRegex path}/.*$") cfg.reverseProxy.authelia.bypassPaths;
    };

    # Backup integration using standardized restic pattern
    modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      overseerr = {
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
  })

    # Preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "overseerr";
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

    # Register with Authelia if SSO protection is enabled
    # This declares INTENT - Caddy module handles IMPLEMENTATION
    (lib.mkIf (
      config.modules.services.authelia.enable &&
      cfg.enable &&
      cfg.reverseProxy != null &&
      cfg.reverseProxy.enable &&
      cfg.reverseProxy.authelia != null &&
      cfg.reverseProxy.authelia.enable
    ) {
      modules.services.authelia.accessControl.declarativelyProtectedServices.overseerr =
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          # Convert groups to Authelia subject format
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          # Authelia will handle ALL bypass logic - no Caddy-level bypass
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
            ++ authCfg.bypassResources;
        };
    })
  ];
}
