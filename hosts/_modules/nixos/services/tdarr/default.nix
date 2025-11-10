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
  cfg = config.modules.services.tdarr;
in
{
  options.modules.services.tdarr = {
    enable = lib.mkEnableOption "Tdarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tdarr";
      description = "Path to Tdarr configuration and database directory";
    };

    transcodeCacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tdarr-cache";
      description = ''
        Path to Tdarr temporary transcoding cache directory.

        This should be on a fast storage device (SSD/NVMe) with ample space.
        Files here are ephemeral and should NOT be backed up.
        Recommended: Dedicated ZFS dataset with compression=off, atime=off.
      '';
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/media";
      description = "Path to media library that Tdarr will transcode";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "920";
      description = "User account under which Tdarr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Tdarr runs.";
    };

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Additional group for NFS media access";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/haveagitgat/tdarr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Avoid 'latest' tag for production systems
      '';
      example = "ghcr.io/haveagitgat/tdarr:2.24.02@sha256:f3ad4f59e6e5e4a...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    enableInternalNode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run a transcode node inside the server container";
    };

    nodeId = lib.mkOption {
      type = lib.types.str;
      default = "mainNode";
      description = "Name for the internal transcode node";
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/dri/renderD128" "/dev/dri/card0" ];
      description = ''
        Device paths for hardware acceleration (VA-API /dev/dri).

        Common configurations:
        - Intel Quick Sync: ["/dev/dri/renderD128" "/dev/dri/card0"]
        - Empty list: CPU-only transcoding

        For NVIDIA GPUs, additional nvidia-container-toolkit setup is required.
      '';
      example = [ "/dev/dri/renderD128" "/dev/dri/card0" ];
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of the NFS mount this service depends on (from modules.storage.nfsMounts)";
      example = "nas-media";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "4G";
        memoryReservation = "2G";
        cpus = "4.0";
      };
      description = "Resource limits for the container (transcoding is resource-intensive)";
    };

    healthcheck = {
      enable = lib.mkEnableOption "container health check";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Frequency of health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Timeout for each health check.";
      };
      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy.";
      };
      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "120s";
        description = "Grace period for container initialization (Tdarr needs time to start MongoDB).";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Tdarr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration for Tdarr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Tdarr";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Tdarr configuration and database.

        NOTE: The transcode cache directory is ephemeral and should NOT be backed up.
        Only the config, database, and transcode profiles are backed up.

        Recommended recordsize: 16K (for MongoDB database files)
      '';
    };

    # Dataset configuration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Tdarr configuration directory";
    };

    # Separate dataset for transcode cache
    cacheDataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = ''
        ZFS dataset configuration for Tdarr transcode cache directory.

        Recommended settings:
        - compression=off (transcoding produces compressed video)
        - atime=off (no need to track access times)
        - Large recordsize (128K or 1M for video files)
        - Exclude from backups (ephemeral data)
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Move config-dependent variables here to avoid infinite recursion
      storageCfg = config.modules.storage;
      tdarrWebPort = 8265;
      tdarrServerPort = 8266;
      mainServiceUnit = "${config.virtualisation.oci-containers.backend}-tdarr.service";
      datasetPath = "${storageCfg.datasets.parentDataset}/tdarr";

      # Look up the NFS mount configuration if a dependency is declared
      nfsMountName = cfg.nfsMountDependency;
      nfsMountConfig =
        if nfsMountName != null
        then config.modules.storage.nfsMounts.${nfsMountName} or null
        else null;

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
    in
    {
    assertions = [
      {
        assertion = cfg.reverseProxy != null -> cfg.reverseProxy.enable;
        message = "Tdarr reverse proxy must be explicitly enabled when configured";
      }
      {
        assertion = cfg.backup != null -> cfg.backup.enable;
        message = "Tdarr backup must be explicitly enabled when configured";
      }
      {
        assertion = nfsMountName == null || nfsMountConfig != null;
        message = "Tdarr references undefined NFS mount '${nfsMountName}'";
      }
    ];

    warnings =
      (lib.optional (cfg.reverseProxy == null) "Tdarr has no reverse proxy configured. Service will only be accessible locally.")
      ++ (lib.optional (cfg.backup == null) "Tdarr has no backup configured. Transcode profiles and database will not be protected.")
      ++ (lib.optional (cfg.accelerationDevices == []) "Tdarr GPU passthrough is disabled. Transcoding will be CPU-only and slower.");

    # Create ZFS datasets for Tdarr configuration and cache
    modules.storage.datasets.services.tdarr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for MongoDB database
      compression = "zstd";
      properties = {
        "com.sun:auto-snapshot" = "true";
      };
      owner = "tdarr";
      group = "tdarr";
      mode = "0750";
    };

    modules.storage.datasets.services.tdarr-cache = {
      mountpoint = cfg.transcodeCacheDir;
      recordsize = "1M";  # Optimal for large transcoding temp files
      compression = "off";  # Don't compress temporary transcode files
      properties = {
        "com.sun:auto-snapshot" = "false";  # Don't snapshot cache
        atime = "off";
      };
      owner = "tdarr";
      group = "tdarr";
      mode = "0750";
    };

    # Create system user for Tdarr
    users.users.tdarr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group;
      isSystemUser = true;
      description = "Tdarr service user";
      # Add to render group for GPU access and media group for NFS access
      extraGroups = lib.optionals (cfg.accelerationDevices != []) [ "render" ]
        ++ lib.optional (nfsMountName != null) cfg.mediaGroup;
    };

    # Tdarr container configuration
    virtualisation.oci-containers.containers.tdarr = podmanLib.mkContainer "tdarr" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = toString config.users.groups.${cfg.group}.gid;
        TZ = cfg.timezone;
        internalNode = if cfg.enableInternalNode then "true" else "false";
        nodeID = cfg.nodeId;
        # MongoDB connection (internal)
        MONGO_URL = "mongodb://localhost:27017/Tdarr";
      };
      volumes = [
        "${cfg.dataDir}/server:/app/server:rw"
        "${cfg.dataDir}/configs:/app/configs:rw"
        "${cfg.dataDir}/logs:/app/logs:rw"
        "${cfg.mediaDir}:/media:rw"
        "${cfg.transcodeCacheDir}:/temp:rw"
      ];
      ports = [
        "${toString tdarrWebPort}:8265"
        "${toString tdarrServerPort}:8266"
      ];
      log-driver = if cfg.logging != null && cfg.logging.enable then cfg.logging.driver else "journald";
      extraOptions =
        (lib.optionals (cfg.accelerationDevices != []) (
          map (dev: "--device=${dev}:${dev}:rwm") cfg.accelerationDevices
        ))
        ++ (lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--memory-reservation=${cfg.resources.memoryReservation}"
          "--cpus=${cfg.resources.cpus}"
        ])
        ++ (lib.optionals (cfg.healthcheck.enable) [
          "--health-cmd=curl --fail http://localhost:8265/api/v2/status || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ]);
    };

    # Systemd service dependencies and security
    systemd.services."${mainServiceUnit}" = {
      requires = [ "network-online.target" ]
        ++ lib.optional (nfsMountName != null) "${nfsMountConfig.mountUnit}";
      after = [ "network-online.target" ]
        ++ lib.optional (nfsMountName != null) "${nfsMountConfig.mountUnit}";
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "30s";
      };
    };

    # Integrate with centralized Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.tdarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = tdarrWebPort;
      };
      auth = cfg.reverseProxy.auth;
      authelia = cfg.reverseProxy.authelia;
      security = cfg.reverseProxy.security;
      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Backup integration using standardized restic pattern (ONLY config/database, NOT cache)
    modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      tdarr = {
        enable = true;
        paths = [ cfg.dataDir ];  # Only backup config/database, not cache
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency;
        tags = cfg.backup.tags;
        excludePatterns = cfg.backup.excludePatterns;
        useSnapshots = cfg.backup.useSnapshots;
        zfsDataset = cfg.backup.zfsDataset;
      };
    };

    # Preseed service for disaster recovery
    systemd.services."tdarr-preseed" = lib.mkIf (cfg.backup != null && cfg.backup.preseed.enable && replicationConfig != null) (
      storageHelpers.makePreseedService {
        serviceName = "tdarr";
        datasetPath = datasetPath;
        mountPoint = cfg.dataDir;
        targetServiceUnit = mainServiceUnit;
        replicationConfig = replicationConfig;
        restoreMethods = cfg.backup.preseed.restoreMethods;
        resticRepository = if cfg.backup.preseed.enableResticRestore then cfg.backup.repository else null;
        user = cfg.user;
        group = cfg.group;
      }
    );
  }
  );
}
