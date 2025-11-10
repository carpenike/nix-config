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

  cfg = config.modules.services.sabnzbd;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-sabnzbd.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/sabnzbd";

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig =
    if nfsMountName != null
    then config.modules.storage.nfsMounts.${nfsMountName} or null
    else null;

  # Recursively find the replication config from the most specific dataset path upwards.
  # This allows a service dataset (e.g., tank/services/sabnzbd) to inherit replication
  # config from a parent dataset (e.g., tank/services) without duplication.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        # Check if replication is defined for the current path (datasets are flat keys, not nested)
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        # Determine the parent path for recursion
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      # If found, return it. Otherwise, recurse to the parent.
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  # Execute the search for the current service's dataset
  foundReplication = findReplication datasetPath;

  # Build the final config attrset to pass to the preseed service.
  # This only evaluates if replication is found and sanoid is enabled, preventing errors.
  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        # Get the suffix, e.g., "sabnzbd" from "tank/services/sabnzbd" relative to "tank/services"
        # Handle exact match case: if source path equals dataset path, suffix is empty
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/sabnzbd"
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        # Pass through sendOptions and recvOptions for syncoid
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.sabnzbd = {
    enable = lib.mkEnableOption "sabnzbd";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sabnzbd";
      description = "Path to SABnzbd data directory (config only)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "916";
      description = "User account under which SABnzbd runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which SABnzbd runs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = ''
        Host port to expose the SABnzbd web interface on. The container's internal
        port is fixed at 8080.
      '';
    };

    # This option is now automatically configured by nfsMountDependency
    downloadsDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/downloads"; # Kept for standalone use, but will be overridden
      description = "Path to downloads directory. Set automatically by nfsMountDependency.";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for downloads.
        This will automatically set `downloadsDir` and systemd dependencies.
      '';
      example = "media";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/sabnzbd:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "4.2.3-ls195")
        - Use digest pinning for immutability (e.g., "4.2.3-ls195@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "lscr.io/linuxserver/sabnzbd:4.2.3-ls195@sha256:f3ad4f59e6e5e4a...";
    };

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group with permissions to the downloads directory, for NFS access.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1G";
        memoryReservation = "512M";
        cpus = "4.0";
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
        description = "Grace period for the container to initialize before failures are counted.";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for SABnzbd web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8081;
        path = "/api?mode=version";
        labels = {
          service_type = "download_client";
          exporter = "sabnzbd";
          function = "usenet";
        };
      };
      description = "Prometheus metrics collection configuration for SABnzbd";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-sabnzbd.service";
        labels = {
          service = "sabnzbd";
          service_type = "download_client";
        };
      };
      description = "Log shipping configuration for SABnzbd logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "sabnzbd" "config" ];
        # CRITICAL: Enable ZFS snapshots for database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/sabnzbd";
        excludePatterns = lib.mkDefault [
          "**/*.log"         # Exclude log files
          "**/cache/**"      # Exclude cache directories
          "**/logs/**"       # Exclude additional log directories
          # NOTE: Downloads are NOT backed up - only configuration
        ];
      };
      description = "Backup configuration for SABnzbd (config only, not downloads)";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        events = {
          onFailure = {
            title = "SABnzbd Failed";
            body = "SABnzbd container has failed on ${config.networking.hostName}";
            priority = "critical";
          };
        };
      };
      description = "Notification channels and events for SABnzbd";
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

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Validate NFS mount dependency if specified
      assertions =
        (lib.optional (nfsMountName != null) {
          assertion = nfsMountConfig != null;
          message = "SABnzbd nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "SABnzbd backup.enable requires backup.repository to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "SABnzbd preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "SABnzbd preseed.enable requires preseed.passwordFile to be set.";
        });

      # Auto-configure downloadsDir from NFS mount configuration
      modules.services.sabnzbd.downloadsDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

    # Integrate with centralized Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.sabnzbd = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";  # SABnzbd uses HTTP locally
        host = "127.0.0.1";
        port = cfg.port;
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Authelia SSO configuration from shared types
      authelia = cfg.reverseProxy.authelia;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Declare dataset requirements for per-service ZFS isolation
    # This integrates with the storage.datasets module to automatically
    # create tank/services/sabnzbd with appropriate ZFS properties
    modules.storage.datasets.services.sabnzbd = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for SQLite databases
      compression = "zstd";  # Better compression for text/config files
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
      };
      # Ownership matches the container user/group
      owner = "sabnzbd";
      group = "sabnzbd";
      mode = "0750";  # Allow group read access for backup systems
    };

    # Create local users to match container UIDs
    # This ensures proper file ownership on the host
    users.users.sabnzbd = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group; # Use configured group (defaults to "media")
      isSystemUser = true;
      description = "SABnzbd service user";
      # Add to media group for NFS access if dependency is set
      extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
    };

    # SABnzbd container configuration
    virtualisation.oci-containers.containers.sabnzbd = podmanLib.mkContainer "sabnzbd" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
        TZ = cfg.timezone;
        UMASK = "002";  # Ensure group-writable files for *arr services to read
      };
      volumes = [
        "${cfg.dataDir}:/config:rw"
        "${cfg.downloadsDir}:/downloads:rw"
        # SECURITY: NO media directory mount - download clients should not have direct media access
      ];
      ports = [
        "${toString cfg.port}:8080"  # Map configurable host port to container port 8080
      ];
      resources = cfg.resources;
      extraOptions = [
        # Podman-level umask ensures container process creates files with group-readable permissions
        # This allows restic-backup user (member of sabnzbd group) to read data
        "--umask=0027"  # Creates directories with 750 and files with 640
        "--pull=newer"  # Automatically pull newer images
        # Force container to run as the specified user:group
        "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
      ] ++ lib.optionals (nfsMountConfig != null) [
        # Add media group to container so process can write to group-owned NFS mount
        "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
      ] ++ lib.optionals cfg.healthcheck.enable [
        # Define the health check on the container itself
        ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/api?mode=version)" = 200 ]' ''
        # CRITICAL: Disable Podman's internal timer to prevent transient systemd units
        "--health-interval=0s"
        "--health-timeout=${cfg.healthcheck.timeout}"
        "--health-retries=${toString cfg.healthcheck.retries}"
        "--health-start-period=${cfg.healthcheck.startPeriod}"
      ];
    };

    # Standardized systemd integration for container restart behavior
    systemd.services."${mainServiceUnit}" = lib.mkMerge [
      (lib.mkIf (nfsMountConfig != null) {
        requires = [ "${config.virtualisation.oci-containers.backend}-media.mount" ];  # TODO: derive from nfsMountConfig.localPath
        after = [ "${config.virtualisation.oci-containers.backend}-media.mount" ];
      })
      {
      # Service should remain stopped if explicitly stopped by admin
      unitConfig = {
        # If the service fails, automatically restart it
        # But if it's stopped manually (systemctl stop), keep it stopped
        StartLimitBurst = 5;
        StartLimitIntervalSec = 300;
      };
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "30s";
        # Add NFS mount dependency if configured
        RequiresMountsFor = lib.optional (nfsMountConfig != null) nfsMountConfig.localPath;
      };
      # Wait for preseed service before starting container
      after = lib.optionals cfg.preseed.enable [
        "sabnzbd-preseed.service"
      ];
      wants = lib.optionals cfg.preseed.enable [
        "sabnzbd-preseed.service"
      ];
      }
    ];

    # Standardized health monitoring service
    systemd.services."sabnzbd-healthcheck" = lib.mkIf cfg.healthcheck.enable {
      description = "SABnzbd Health Check";
      after = [ mainServiceUnit ];
      requires = [ mainServiceUnit ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.podman}/bin/podman healthcheck run sabnzbd";
        # Health checks should not restart the service
        Restart = "no";
      };
    };

    systemd.timers."sabnzbd-healthcheck" = lib.mkIf cfg.healthcheck.enable {
      description = "Timer for SABnzbd Health Check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnUnitActiveSec = cfg.healthcheck.interval;
        OnBootSec = cfg.healthcheck.startPeriod;
        Unit = "sabnzbd-healthcheck.service";
      };
    };

    # Notifications for service failures (centralized pattern)
    modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
      "sabnzbd-failure" = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = lib.mkDefault ''<b><font color="red">✗ Service Failed: SABnzbd</font></b>'';
        body = lib.mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The SABnzbd usenet download client has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
    };

    # Backup integration using standardized restic pattern
    modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      sabnzbd = {
        enable = true;
        # Configuration directory only - downloads are transient and not backed up
        paths = [ cfg.dataDir ];
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency;
        tags = cfg.backup.tags;
        excludePatterns = cfg.backup.excludePatterns;
        # Use ZFS snapshots for consistent backups of SQLite databases
        useSnapshots = cfg.backup.useSnapshots;
        zfsDataset = cfg.backup.zfsDataset;
        # Ensure service stops before backup for data consistency
        preBackupServices = [ mainServiceUnit ];
      };
    };

    })

    # Add the preseed service using the standard helper
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "sabnzbd";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;  # Pass the auto-discovered replication config
        datasetProperties = {
          recordsize = "16K";    # Optimal for application data
          compression = "zstd";  # Better compression for config files
          "com.sun:auto-snapshot" = "true";  # Enable sanoid snapshots for this dataset
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
