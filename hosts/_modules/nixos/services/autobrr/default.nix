{
  lib,
  pkgs,
  config,
  podmanLib,
  ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Only cfg is needed at top level for mkIf condition
  cfg = config.modules.services.autobrr;
in
{
  options.modules.services.autobrr = {
    enable = lib.mkEnableOption "Autobrr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/autobrr";
      description = "Path to Autobrr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "919";
      description = "User account under which Autobrr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Autobrr runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/autobrr/autobrr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/autobrr/autobrr:v1.42.0@sha256:f3ad4f59e6e5e4a...";
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
        cpus = "0.5";
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
        default = "30s";
        description = "Grace period for container initialization.";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Autobrr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration for Autobrr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Autobrr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Autobrr IRC announce bot failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Autobrr service events";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Autobrr data.

        Autobrr stores configuration, filters, and IRC connection state in its database.

        Recommended recordsize: 16K (optimal for database files)
      '';
    };

    # Dataset configuration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Autobrr data directory";
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
    autobrrPort = 7474;
    mainServiceUnit = "${config.virtualisation.oci-containers.backend}-autobrr.service";
    datasetPath = "${storageCfg.datasets.parentDataset}/autobrr";

      # Recursively find the replication config
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
          message = "Autobrr reverse proxy must be explicitly enabled when configured";
        }
        {
          assertion = cfg.backup != null -> cfg.backup.enable;
          message = "Autobrr backup must be explicitly enabled when configured";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
          message = "Autobrr preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
          message = "Autobrr preseed.enable requires preseed.passwordFile to be set.";
        }
      ];

    warnings =
      (lib.optional (cfg.reverseProxy == null) "Autobrr has no reverse proxy configured. Service will only be accessible locally.")
      ++ (lib.optional (cfg.backup == null) "Autobrr has no backup configured. IRC filters and configurations will not be protected.");

    # Create ZFS dataset for Autobrr data
    modules.storage.datasets.services.autobrr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for configuration files
      compression = "zstd";
      properties = {
        "com.sun:auto-snapshot" = "true";
      };
      owner = cfg.user;
      group = cfg.group;
      mode = "0750";
    };

    # Create system user for Autobrr
    users.users.autobrr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group;
      isSystemUser = true;
      description = "Autobrr service user";
    };

    # Create system group for Autobrr
    users.groups.autobrr = {
      gid = lib.mkDefault (lib.toInt cfg.user);
    };

    # Autobrr container configuration
    # Note: This image does not use PUID/PGID - must use --user flag
    virtualisation.oci-containers.containers.autobrr = podmanLib.mkContainer "autobrr" {
      image = cfg.image;
      environment = {
        TZ = cfg.timezone;
      };
      volumes = [
        "${cfg.dataDir}:/config:rw"
      ];
      ports = [ "${toString autobrrPort}:7474" ];
      log-driver = "journald";
      extraOptions =
        [
          # Autobrr container doesn't support PUID/PGID - use --user flag
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ]
        ++ (lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--memory-reservation=${cfg.resources.memoryReservation}"
          "--cpus=${cfg.resources.cpus}"
        ])
        ++ (lib.optionals (cfg.healthcheck.enable) [
          "--health-cmd=curl --fail http://localhost:7474/api/healthz/liveness || exit 1"
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
    modules.services.caddy.virtualHosts.autobrr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = autobrrPort;
      };
      auth = cfg.reverseProxy.auth;
      authelia = cfg.reverseProxy.authelia;
      security = cfg.reverseProxy.security;
      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Register with Authelia for SSO protection
    modules.services.authelia.accessControl.declarativelyProtectedServices.autobrr = lib.mkIf (
      cfg.reverseProxy != null && cfg.reverseProxy.enable && cfg.reverseProxy.authelia.enable
    ) {
      domain = cfg.reverseProxy.hostName;
      policy = cfg.reverseProxy.authelia.policy;
      subject = map (group: "group:${group}") cfg.reverseProxy.authelia.allowedGroups;
      bypassResources = map (path: "^${lib.escapeRegex path}/.*$") cfg.reverseProxy.authelia.bypassPaths;
    };

    # Backup integration using standardized restic pattern
    modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      autobrr = {
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
        serviceName = "autobrr";
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
      modules.services.authelia.accessControl.declarativelyProtectedServices.autobrr =
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
            ++ authCfg.bypassResources;
        };
    })
  ];
}
