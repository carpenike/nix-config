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

  cfg = config.modules.services.sonarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  sonarrPort = 8989;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-sonarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/sonarr";

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig =
    if nfsMountName != null
    then config.modules.storage.nfsMounts.${nfsMountName} or null
    else null;

  # Recursively find the replication config from the most specific dataset path upwards.
  # This allows a service dataset (e.g., tank/services/sonarr) to inherit replication
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
        # Get the suffix, e.g., "sonarr" from "tank/services/sonarr" relative to "tank/services"
        datasetSuffix = lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/sonarr"
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
  options.modules.services.sonarr = {
    enable = lib.mkEnableOption "sonarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sonarr";
      description = "Path to Sonarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "568";
      description = "User ID to own the data directory (sonarr:sonarr in container)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "568";
      description = "Group ID to own the data directory";
    };

    # This option is now automatically configured by nfsMountDependency
    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/media"; # Kept for standalone use, but will be overridden
      description = "Path to media library. Set automatically by nfsMountDependency.";
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for media.
        This will automatically set `mediaDir` and systemd dependencies.
      '';
      example = "media";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/sonarr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "4.0.4.1491-ls185")
        - Use digest pinning for immutability (e.g., "4.0.4.1491-ls185@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185@sha256:f3ad4f59e6e5e4a...";
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
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "512m";
            description = "Memory limit for the container";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "2.0";
            description = "CPU limit for the container";
          };
        };
      });
      default = { memory = "512m"; cpus = "2.0"; };
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
        description = "Grace period for the container to initialize before failures are counted. Allows time for DB migrations, preseed operations, and first-run initialization.";
      };
    };

    backup = {
      enable = lib.mkEnableOption "backup for Sonarr data";
      repository = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the Restic repository to use for backups. Should reference primaryRepo.name from host config.";
      };
    };

    notifications = {
      enable = lib.mkEnableOption "failure notifications for the Sonarr service";
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
          message = "Sonarr nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional cfg.backup.enable {
          assertion = cfg.backup.repository != null;
          message = "Sonarr backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Sonarr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Sonarr preseed.enable requires preseed.passwordFile to be set.";
        });

    # Automatically set mediaDir from the NFS mount configuration
    modules.services.sonarr.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

    # Declare dataset requirements for per-service ZFS isolation
    # This integrates with the storage.datasets module to automatically
    # create tank/services/sonarr with appropriate ZFS properties
    modules.storage.datasets.services.sonarr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for SQLite databases
      compression = "zstd";  # Better compression for text/config files
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
      };
      # Ownership matches the container user/group
      owner = "sonarr";
      group = "sonarr";
      mode = "0700";  # Restrictive permissions
    };

    # Create local users to match container UIDs
    # This ensures proper file ownership on the host
    users.users.sonarr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = "sonarr";
      isSystemUser = true;
      description = "Sonarr service user";
      # Add to media group for NFS access if dependency is set
      extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
    };

    users.groups.sonarr = {
      gid = lib.mkDefault (lib.toInt cfg.group);
    };

    # Sonarr container configuration
    virtualisation.oci-containers.containers.sonarr = podmanLib.mkContainer "sonarr" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = cfg.group;
        TZ = cfg.timezone;
      };
      volumes = [
        "${cfg.dataDir}:/config:rw"
        "${cfg.mediaDir}:/media:rw"
      ];
      ports = [
        "${toString sonarrPort}:8989"
      ];
      resources = cfg.resources;
      extraOptions = [
        "--pull=newer"  # Automatically pull newer images
      ] ++ lib.optionals cfg.healthcheck.enable [
        # Container-native health check using Podman health check options
        # Use /ping endpoint - unauthenticated, stable endpoint for Sonarr v3/v4
        # Requires exactly HTTP 200 to avoid counting redirects or auth pages as healthy
        # Uses 127.0.0.1 to avoid IPv6/resolver issues; curl timeouts stay within the configured timeout
        ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8989/ping)" = 200 ]' ''
        "--health-interval=${cfg.healthcheck.interval}"
        "--health-timeout=${cfg.healthcheck.timeout}"
        "--health-retries=${toString cfg.healthcheck.retries}"
        "--health-start-period=${cfg.healthcheck.startPeriod}"
      ];
    };

    # Add systemd dependencies for the NFS mount
    systemd.services."${config.virtualisation.oci-containers.backend}-sonarr" = lib.mkMerge [
      (lib.mkIf (nfsMountConfig != null) {
        requires = [ nfsMountConfig.mountUnitName ];
        after = [ nfsMountConfig.mountUnitName ];
      })
      # Add failure notifications via systemd
      (lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
        unitConfig.OnFailure = [ "notify@sonarr-failure:%n.service" ];
      })
      # Add dependency on the preseed service
      (lib.mkIf cfg.preseed.enable {
        wants = [ "preseed-sonarr.service" ];
        after = [ "preseed-sonarr.service" ];
      })
    ];

    # Override Podman's auto-generated health check timer to prevent activation failures
    # Podman creates systemd timers for containers with --health-* flags, but these
    # timers run immediately during activation, before the --health-start-period expires.
    # This causes systemd to report failed units during nixos-rebuild switch.
    systemd.timers."podman-healthcheck@" = lib.mkIf cfg.healthcheck.enable {
      timerConfig = {
        # Delay the first health check until after the timer unit is activated.
        # OnActiveSec schedules relative to timer activation (not boot), making it work
        # correctly during nixos-rebuild switch when the system doesn't reboot.
        OnActiveSec = cfg.healthcheck.startPeriod;  # e.g., "180s"
        # The regular interval (OnUnitActiveSec) is already set by Podman's timer,
        # this override only adds the initial activation delay.
      };
    };

    # Configure the health check service to tolerate "starting" status
    systemd.services."podman-healthcheck@" = lib.mkIf cfg.healthcheck.enable {
      serviceConfig = {
        # Treat exit codes 0, 1, and 2 as success
        # 0 = healthy, 1 = unhealthy (but expected during start), 2 = starting
        # This prevents systemd from marking the unit as failed during the start period
        SuccessExitStatus = "0 1 2";
      };
    };

    # Register notification template
    modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
      "sonarr-failure" = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Sonarr</font></b>'';
        body = lib.mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Sonarr service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
    };

    # Integrate with backup system
    # Reuses existing backup infrastructure (Restic, notifications, etc.)
    modules.backup.restic.jobs.sonarr = lib.mkIf (config.modules.backup.enable && cfg.backup.enable) {
      enable = true;
      paths = [ cfg.dataDir ];
      excludePatterns = [
        "**/.cache"
        "**/cache"
        "**/*.tmp"
        "**/logs/*.txt"  # Exclude verbose logs
      ];
      repository = cfg.backup.repository;
      tags = [ "sonarr" "media" "database" ];
    };

      # Optional: Open firewall for Sonarr web UI
      # Disabled by default since forge has firewall.enable = false
      # networking.firewall.allowedTCPPorts = [ sonarrPort ];
    })

    # Add the preseed service itself
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "sonarr";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;  # Pass the auto-discovered replication config
        datasetProperties = {
          recordsize = "16K";    # Optimal for SQLite databases
          compression = "zstd";  # Better compression for text/config files
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
