{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  # Import shared type definitions
  sharedTypes = mylib.types;
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.prowlarr;

  cfg = config.modules.services.prowlarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  prowlarrPort = 9696;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-prowlarr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/prowlarr";
  usesExternalAuth =
    cfg.reverseProxy != null
    && cfg.reverseProxy.enable
    && (cfg.reverseProxy.caddySecurity != null && cfg.reverseProxy.caddySecurity.enable);

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.prowlarr = {
    enable = lib.mkEnableOption "Prowlarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prowlarr";
      description = "Path to Prowlarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = toString serviceIds.uid;
      description = "User account under which Prowlarr runs (from lib/service-uids.nix).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which Prowlarr runs.";
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
      default = "ghcr.io/home-operations/prowlarr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability (e.g., "1.18.1@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/home-operations/prowlarr:1.18.1@sha256:f3ad4f59e6e5e4a...";
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

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "300s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Prowlarr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 9696;
        path = "/metrics"; # Prowlarr exposes a native Prometheus endpoint
        labels = {
          service_type = "indexer_management";
          exporter = "prowlarr";
          function = "indexer_proxy";
        };
      };
      description = "Prometheus metrics collection configuration for Prowlarr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-prowlarr.service";
        labels = {
          service = "prowlarr";
          service_type = "indexer_management";
        };
      };
      description = "Log shipping configuration for Prowlarr logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "indexer" "prowlarr" "config" ];
        # CRITICAL: Enable ZFS snapshots for SQLite database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/prowlarr";
        excludePatterns = lib.mkDefault [
          "**/*.log" # Exclude log files
          "**/cache/**" # Exclude cache directories
          "**/logs/**" # Exclude additional log directories
        ];
      };
      description = "Backup configuration for Prowlarr. This is critical as it stores all indexer configurations.";
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
          failure = "Prowlarr indexer management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Prowlarr service events";
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
      # Validate dependencies
      assertions =
        (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Prowlarr backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Prowlarr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Prowlarr preseed.enable requires preseed.passwordFile to be set.";
        });

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.prowlarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = prowlarrPort;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Declare dataset requirements for per-service ZFS isolation
      modules.storage.datasets.services.prowlarr = {
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
      users.users.prowlarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group; # Use configured group (defaults to "media")
        isSystemUser = true;
        description = "Prowlarr service user";
      };

      # Group is expected to be pre-defined (e.g., media group with GID 65537)
      # users.groups.prowlarr removed - use shared media group instead

      # Prowlarr container configuration
      virtualisation.oci-containers.containers.prowlarr = podmanLib.mkContainer "prowlarr" {
        image = cfg.image;
        environment = {
          PUID = cfg.user;
          PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
          TZ = cfg.timezone;
          UMASK = "002"; # Ensure group-writable files on shared media
          PROWLARR__AUTH__METHOD = if usesExternalAuth then "External" else "None";
        };
        environmentFiles = [
          # Pre-generated API key for declarative configuration
          # Allows cross-seed and other services to integrate from first startup
          # See: https://wiki.servarr.com/prowlarr/environment-variables
          config.sops.templates."prowlarr-env".path
        ];
        volumes = [
          "${cfg.dataDir}:/config:rw"
        ];
        ports = [
          "9696:9696"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Define the health check on the container itself.
          # This allows `podman healthcheck run` to work and updates status in `podman ps`.
          # Use explicit HTTP 200 check to avoid false positives from redirects
          # Prowlarr runs on port 9696 by default
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:9696/ping)" = 200 ]' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          # When unhealthy, take configured action (default: kill so systemd can restart)
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          "--network=${cfg.podmanNetwork}"
        ];
      };

      # Add systemd dependencies for the service
      systemd.services."${config.virtualisation.oci-containers.backend}-prowlarr" = lib.mkMerge [
        # Add Podman network dependency if configured
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@prowlarr-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-prowlarr.service" ];
          after = [ "preseed-prowlarr.service" ];
        })
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "prowlarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Prowlarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Prowlarr service has entered a failed state.

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
        serviceName = "prowlarr";
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
