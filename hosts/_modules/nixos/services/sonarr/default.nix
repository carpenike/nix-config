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
        # Handle exact match case: if source path equals dataset path, suffix is empty
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
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
      description = "User account under which Sonarr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which Sonarr runs.";
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
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
  memory = "512M";
  memoryReservation = "256M";
        cpus = "2.0";
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
        description = "Grace period for the container to initialize before failures are counted. Allows time for DB migrations, preseed operations, and first-run initialization.";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Sonarr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8989;
        path = "/api/v3/health";
        labels = {
          service_type = "media_management";
          exporter = "sonarr";
          function = "tv_series";
        };
      };
      description = "Prometheus metrics collection configuration for Sonarr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-sonarr.service";
        labels = {
          service = "sonarr";
          service_type = "media_management";
        };
      };
      description = "Log shipping configuration for Sonarr logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "sonarr" "config" ];
        # CRITICAL: Enable ZFS snapshots for SQLite database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/sonarr";
        excludePatterns = lib.mkDefault [
          "**/*.log"         # Exclude log files
          "**/cache/**"      # Exclude cache directories
          "**/logs/**"       # Exclude additional log directories
        ];
      };
      description = "Backup configuration for Sonarr";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Sonarr media management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Sonarr service events";
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
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
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

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.sonarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";  # Sonarr uses HTTP locally
        host = "127.0.0.1";
        port = sonarrPort;
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Authelia SSO configuration from shared types
      authelia = cfg.reverseProxy.authelia;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Register with Authelia if SSO protection is enabled
    # This declares INTENT - Caddy module handles IMPLEMENTATION
    modules.services.authelia.accessControl.declarativelyProtectedServices.sonarr = lib.mkIf (
      config.modules.services.authelia.enable &&  # Check global Authelia is enabled
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
        # Convert groups to Authelia subject format
        subject = map (g: "group:${g}") authCfg.allowedGroups;
        # Authelia will handle ALL bypass logic - no Caddy-level bypass
        bypassResources =
          (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
          ++ authCfg.bypassResources;
      }
    );

    # Declare dataset requirements for per-service ZFS isolation
    # This integrates with the storage.datasets module to automatically
    # create tank/services/sonarr with appropriate ZFS properties
    # Note: OCI containers don't support StateDirectory, so we explicitly set permissions
    # via tmpfiles by keeping owner/group/mode here
    modules.storage.datasets.services.sonarr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for SQLite databases
      compression = "zstd";  # Better compression for text/config files
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
        # snapdir managed by sanoid module - no longer needed with clone-based backups
      };
      # Ownership matches the container user/group
      owner = cfg.user;
      group = cfg.group;  # Use configured group (defaults to "media")
      mode = "0750";  # Allow group read access for backup systems
    };

    # NOTE: ZFS snapshots and replication for sonarr dataset should be configured
    # in the host-level config (e.g., hosts/forge/default.nix), not here.
    # Reason: Replication targets are host-specific (forge → nas-1, luna → nas-2, etc.)
    # Defining them in a shared module would hardcode "forge" in the target path,
    # breaking reusability across different hosts.

    # Create local users to match container UIDs
    # This ensures proper file ownership on the host
    users.users.sonarr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group; # Use configured group (defaults to "media")
      isSystemUser = true;
      description = "Sonarr service user";
      # Add to media group for NFS access if dependency is set
      extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
    };

    # Group is expected to be pre-defined (e.g., media group with GID 65537)
    # users.groups.sonarr removed - use shared media group instead

    # Sonarr container configuration
    virtualisation.oci-containers.containers.sonarr = podmanLib.mkContainer "sonarr" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
        TZ = cfg.timezone;
        UMASK = "002";  # Ensure group-writable files on shared media

        # Authentication handled entirely by Authelia/Caddy upstream
        # Sonarr is set to "External" mode - it trusts that any request reaching it has been authenticated
        # Note: Sonarr does NOT support multiple users - everyone who passes Authelia gets admin access
        # Authelia's allowedGroups controls WHO can access, but Sonarr has no per-user authorization
        SONARR__AUTH__METHOD = if (cfg.reverseProxy != null && cfg.reverseProxy.authelia != null && cfg.reverseProxy.authelia.enable) then "External" else "None";
      };
      environmentFiles = [
        # Pre-generated API key for declarative configuration
        # Allows Bazarr and other services to integrate from first startup
        # See: https://wiki.servarr.com/sonarr/environment-variables
        config.sops.templates."sonarr-env".path
      ];
      volumes = [
        "${cfg.dataDir}:/config:rw"
        "${cfg.mediaDir}:/media:rw"
      ];
      ports = [
        "${toString sonarrPort}:8989"
      ];
      resources = cfg.resources;
      extraOptions = [
        # Podman-level umask ensures container process creates files with group-readable permissions
        # This allows restic-backup user (member of sonarr group) to read data
        "--umask=0027"  # Creates directories with 750 and files with 640
        "--pull=newer"  # Automatically pull newer images
        # Force container to run as the specified user:group
        # This is required for containers that don't process PUID/PGID environment variables
        "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
      ] ++ lib.optionals (nfsMountConfig != null) [
        # Add media group to container so process can write to group-owned NFS mount
        # Host user's extraGroups doesn't propagate into container namespace
        "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
      ] ++ lib.optionals cfg.healthcheck.enable [
        # Define the health check on the container itself.
        # This allows `podman healthcheck run` to work and updates status in `podman ps`.
        # Use explicit HTTP 200 check to avoid false positives from redirects
        ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8989/ping)" = 200 ]' ''
        # CRITICAL: Disable Podman's internal timer to prevent transient systemd units.
        # Use "0s" instead of "disable" for better Podman version compatibility
        "--health-interval=0s"
        "--health-timeout=${cfg.healthcheck.timeout}"
        "--health-retries=${toString cfg.healthcheck.retries}"
        "--health-start-period=${cfg.healthcheck.startPeriod}"
      ] ++ lib.optionals (cfg.podmanNetwork != null) [
        "--network=${cfg.podmanNetwork}"
      ];
    };

    # Add systemd dependencies for the NFS mount and Podman network
    systemd.services."${config.virtualisation.oci-containers.backend}-sonarr" = lib.mkMerge [
      # Add Podman network dependency if configured
      (lib.mkIf (cfg.podmanNetwork != null) {
        requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
        after = [ "podman-network-${cfg.podmanNetwork}.service" ];
      })
      (lib.mkIf (nfsMountConfig != null) {
        requires = [ nfsMountConfig.mountUnitName ];
        after = [ nfsMountConfig.mountUnitName ];
      })
      # Add failure notifications via systemd
      (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        unitConfig.OnFailure = [ "notify@sonarr-failure:%n.service" ];
      })
      # Add dependency on the preseed service
      (lib.mkIf cfg.preseed.enable {
        wants = [ "preseed-sonarr.service" ];
        after = [ "preseed-sonarr.service" ];
      })
    ];

    # Create explicit health check timer/service that we control
    # We don't use Podman's native --health-* flags because they create transient units
    # that bypass systemd overrides and cause activation failures
    systemd.timers.sonarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
      description = "Sonarr Container Health Check Timer";
      wantedBy = [ "timers.target" ];
      after = [ mainServiceUnit ];
      timerConfig = {
        # Delay first check to allow container initialization
        OnActiveSec = cfg.healthcheck.startPeriod;  # e.g., "300s"
        # Regular interval for subsequent checks
        OnUnitActiveSec = cfg.healthcheck.interval;  # e.g., "30s"
        # Continue timer even if check fails
        Persistent = false;
      };
    };

    systemd.services.sonarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
      description = "Sonarr Container Health Check";
      after = [ mainServiceUnit ];
      serviceConfig = {
        Type = "oneshot";
        # We allow the unit to fail for better observability. The timer's OnActiveSec
        # provides the startup grace period, and after that we want genuine failures
        # to be visible in systemctl --failed for monitoring.
        ExecStart = pkgs.writeShellScript "sonarr-healthcheck" ''
          set -euo pipefail

          # 1. Check if container is running to avoid unnecessary errors
          if ! ${pkgs.podman}/bin/podman inspect sonarr --format '{{.State.Running}}' | grep -q true; then
            echo "Container sonarr is not running, skipping health check."
            exit 1
          fi

          # 2. Run the health check defined in the container.
          # This updates the container's status for `podman ps` and exits with
          # a proper status code for systemd.
          if ${pkgs.podman}/bin/podman healthcheck run sonarr; then
            echo "Health check passed."
            exit 0
          else
            echo "Health check failed."
            exit 1
          fi
        '';
      };
    };

    # Register notification template
    modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
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

    # Note: Backup integration now handled by backup-integration module
    # The backup submodule configuration will be auto-discovered and converted
    # to a Restic job named "service-sonarr" with the specified settings

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
