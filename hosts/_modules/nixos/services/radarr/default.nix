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

  cfg = config.modules.services.radarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  radarrPort = 7878;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-radarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/radarr";
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
  # This allows a service dataset (e.g., tank/services/radarr) to inherit replication
  # config from a parent dataset (e.g., tank/services) without duplication.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        # Check if replication is defined for the current path (datasets are flat keys, not nested)
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
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
        # Get the suffix, e.g., "radarr" from "tank/services/radarr" relative to "tank/services"
        # Handle exact match case: if source path equals dataset path, suffix is empty
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/radarr"
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
  options.modules.services.radarr = {
    enable = lib.mkEnableOption "Radarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/radarr";
      description = "Path to Radarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "913";
      description = "User account under which Radarr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which Radarr runs.";
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
      default = "ghcr.io/home-operations/radarr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "5.2.6-ls153")
        - Use digest pinning for immutability (e.g., "5.2.6-ls153@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/linuxserver/radarr:5.2.6-ls153@sha256:f3ad4f59e6e5e4a...";
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
      description = "Reverse proxy configuration for Radarr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 7878;
        path = "/metrics"; # Radarr exposes a native Prometheus endpoint
        labels = {
          service_type = "media_management";
          exporter = "radarr";
          function = "movies";
        };
      };
      description = "Prometheus metrics collection configuration for Radarr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-radarr.service";
        labels = {
          service = "radarr";
          service_type = "media_management";
        };
      };
      description = "Log shipping configuration for Radarr logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "radarr" "config" ];
        # CRITICAL: Enable ZFS snapshots for SQLite database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/radarr";
        excludePatterns = lib.mkDefault [
          "**/*.log" # Exclude log files
          "**/cache/**" # Exclude cache directories
          "**/logs/**" # Exclude additional log directories
        ];
      };
      description = "Backup configuration for Radarr";
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
          failure = "Radarr media management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Radarr service events";
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
          sequentially until one succeeds.
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
          message = "Radarr nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Radarr backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Radarr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Radarr preseed.enable requires preseed.passwordFile to be set.";
        });

      # Automatically set mediaDir from the NFS mount configuration
      modules.services.radarr.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.radarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = radarrPort;
        };
        auth = cfg.reverseProxy.auth;
        authelia = cfg.reverseProxy.authelia;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Declare dataset requirements for per-service ZFS isolation
      modules.storage.datasets.services.radarr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite databases
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user; # Use configured user
        group = cfg.group; # Use configured group
        mode = "0750";
      };

      # Create local users to match container UIDs
      users.users.radarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group; # Use configured group (defaults to "media")
        isSystemUser = true;
        description = "Radarr service user";
        # Add to media group for NFS access if dependency is set
        extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
      };

      # Group is expected to be pre-defined (e.g., media group with GID 65537)
      # users.groups.radarr removed - use shared media group instead

      # Radarr container configuration
      virtualisation.oci-containers.containers.radarr = podmanLib.mkContainer "radarr" {
        image = cfg.image;
        environment = {
          PUID = cfg.user;
          PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
          TZ = cfg.timezone;
          UMASK = "002"; # Ensure group-writable files on shared media
          RADARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
        };
        environmentFiles = [
          # Pre-generated API key for declarative configuration
          # Allows Bazarr and other services to integrate from first startup
          # See: https://wiki.servarr.com/radarr/environment-variables
          config.sops.templates."radarr-env".path
        ];
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.mediaDir}:/data:rw" # Unified mount point for hardlinks (TRaSH Guides best practice)
        ];
        ports = [
          "${toString radarrPort}:7878"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--umask=0027"
          "--pull=newer"
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals (nfsMountConfig != null) [
          # Add media group to container so process can write to group-owned NFS mount
          "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:7878/ping)" = 200 ]' ''
          "--health-interval=0s"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          "--network=${cfg.podmanNetwork}"
        ];
      };

      # Add systemd dependencies for the NFS mount, Podman network, and preseed service
      systemd.services."${config.virtualisation.oci-containers.backend}-radarr" = lib.mkMerge [
        # Add Podman network dependency if configured
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ nfsMountConfig.mountUnitName ];
          after = [ nfsMountConfig.mountUnitName ];
        })
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@radarr-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-radarr.service" ];
          after = [ "preseed-radarr.service" ];
        })
      ];

      # Create explicit health check timer/service
      systemd.timers.radarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Radarr Container Health Check Timer";
        wantedBy = [ "timers.target" ];
        after = [ mainServiceUnit ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.radarr-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "Radarr Health Check";
        after = [ mainServiceUnit ];
        requires = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "radarr-healthcheck" ''
            set -euo pipefail
            if ! ${pkgs.podman}/bin/podman inspect radarr --format '{{.State.Running}}' | grep -q true; then
              echo "Container radarr is not running, skipping health check."
              exit 1
            fi
            if ${pkgs.podman}/bin/podman healthcheck run radarr; then
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
        "radarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Radarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Radarr service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Add the preseed service itself
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "radarr";
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
