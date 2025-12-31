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

  # Only cfg is needed at top level for mkIf condition
  cfg = config.modules.services.seerr;
in
{
  options.modules.services.seerr = {
    enable = lib.mkEnableOption "Seerr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/seerr";
      description = "Path to Seerr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "923";
      description = "User account under which Seerr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Seerr runs.";
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
      default = "ghcr.io/seerr-team/seerr:sha-b66b361@sha256:1f562fb32eeb765f58661e3cee1001a573f038c5e981bee85539b9aa85473dfe";
      description = ''
        Full container image name including tag or digest.

        This uses the official Seerr image from ghcr.io/seerr-team/seerr.

        Seerr is the rebranded/merged successor to Overseerr and Jellyseerr.
        Migration from Overseerr/Jellyseerr is automatic on first start.

        Best practices:
        - Pin to specific version tags (e.g., "v2.7.4")
        - Use digest pinning for immutability (e.g., "v2.7.4@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/seerr-team/seerr:v2.7.4@sha256:f3ad4f59e6e5e4a...";
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
      description = ''
        Resource limits for the container.

        Note: Default 512MB memory may be insufficient for large libraries (50K+ items).
        Monitor memory usage and increase limits if you observe OOM kills or performance degradation.
        Consider scaling to 1-2GB for production environments with extensive media collections.
      '';
    };

    dependsOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of service names that Seerr depends on (e.g., "sonarr", "radarr").

        This ensures Seerr starts after its dependencies are ready, preventing
        connection errors and log spam during startup. Service names should match
        the base service name without the "podman-" prefix or ".service" suffix.

        Example: `dependsOn = [ "sonarr" "radarr" ];`
      '';
      example = [ "sonarr" "radarr" ];
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Seerr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration for Seerr (no native metrics support)";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Seerr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Seerr request management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Seerr service events";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Seerr data.

        Seerr stores all configuration and user data in a SQLite database at /var/lib/seerr.
        This includes request history, user settings, and integration configurations.

        Recommended recordsize: 16K (optimal for SQLite databases)
      '';
    };

    # Dataset configuration with storage helper integration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Seerr data directory";
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

  config =
    let
      # Move config-dependent variables here to avoid infinite recursion
      storageCfg = config.modules.storage;
      seerrPort = 5055;
      mainServiceUnit = "${config.virtualisation.oci-containers.backend}-seerr.service";
      datasetPath = "${storageCfg.datasets.parentDataset}/seerr";

      # Build replication config for preseed (walks up dataset tree to find inherited config)
      replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

      hasCentralizedNotifications = config.modules.notifications.alertmanager.enable or false;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.reverseProxy != null -> cfg.reverseProxy.enable;
            message = "Seerr reverse proxy must be explicitly enabled when configured";
          }
          {
            assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
            message = "Seerr preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
            message = "Seerr preseed.enable requires preseed.passwordFile to be set.";
          }
          {
            assertion = cfg.backup != null -> cfg.backup.enable;
            message = "Seerr backup must be explicitly enabled when configured";
          }
        ];

        # Warnings for missing critical configuration
        warnings =
          (lib.optional (cfg.reverseProxy == null) "Seerr has no reverse proxy configured. Service will only be accessible locally.")
          ++ (lib.optional (cfg.backup == null) "Seerr has no backup configured. User data and settings will not be protected.");

        # Create ZFS dataset for Seerr data
        modules.storage.datasets.services.seerr = {
          mountpoint = cfg.dataDir;
          # 16K recordsize is optimal for SQLite databases (Seerr uses SQLite for all data storage)
          # Rationale: SQLite's default page size is 4KB, but modern SSDs benefit from larger block sizes.
          # 16K provides a balance between:
          # - Reduced write amplification (fewer ZFS metadata updates per SQLite transaction)
          # - Efficient SSD alignment (matches common NAND page sizes)
          # - Minimal read overhead (SQLite rarely needs sub-16K reads)
          # This is a well-established best practice for SQLite on ZFS.
          recordsize = "16K";
          compression = "zstd";
          properties = {
            "com.sun:auto-snapshot" = "true";
          };
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        # Create system user for Seerr
        users.users.seerr = {
          uid = lib.mkDefault (lib.toInt cfg.user);
          group = cfg.group;
          isSystemUser = true;
          description = "Seerr service user";
        };

        # Create system group for Seerr
        users.groups.seerr = {
          gid = lib.mkDefault (lib.toInt cfg.user);
        };

        # Seerr container configuration
        # Uses official ghcr.io/seerr-team/seerr image which expects:
        # - Config at /app/config
        # - Container runs as node user (UID 1000) by default
        # - TZ and LOG_LEVEL environment variables
        # - --init flag is required (container does not provide init process)
        virtualisation.oci-containers.containers.seerr = podmanLib.mkContainer "seerr" {
          image = cfg.image;
          environment = {
            TZ = cfg.timezone;
            LOG_LEVEL = "info";
          };
          volumes = [
            "${cfg.dataDir}:/app/config:rw"
          ];
          ports = [ "${toString seerrPort}:5055" ];
          log-driver = "journald";
          extraOptions =
            # The --init flag is required as the container doesn't provide an init process
            [ "--init" ]
            ++ [ "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}" ]
            ++ (lib.optionals (cfg.resources != null) [
              "--memory=${cfg.resources.memory}"
              "--memory-reservation=${cfg.resources.memoryReservation}"
              "--cpus=${cfg.resources.cpus}"
            ])
            ++ (lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
              # Use /login endpoint instead of /api/v1/status - the status API tries to reach
              # external services (Plex, Sonarr, etc.) and times out if they're unreachable
              "--health-cmd=wget --no-verbose --tries=1 --spider http://localhost:5055/login || exit 1"
              "--health-interval=${cfg.healthcheck.interval}"
              "--health-timeout=${cfg.healthcheck.timeout}"
              "--health-retries=${toString cfg.healthcheck.retries}"
              "--health-start-period=${cfg.healthcheck.startPeriod}"
              "--health-on-failure=${cfg.healthcheck.onFailure}"
            ] ++ lib.optionals (cfg.podmanNetwork != null) [
              "--network=${cfg.podmanNetwork}"
            ]);
        };

        # Systemd service dependencies and security
        systemd.services."${mainServiceUnit}" = lib.mkMerge [
          {
            requires = [ "network-online.target" ]
              ++ lib.optionals (cfg.podmanNetwork != null) [ "podman-network-${cfg.podmanNetwork}.service" ]
              ++ (map (s: "${config.virtualisation.oci-containers.backend}-${s}.service") cfg.dependsOn);
            after = [ "network-online.target" ]
              ++ lib.optionals (cfg.podmanNetwork != null) [ "podman-network-${cfg.podmanNetwork}.service" ]
              ++ (map (s: "${config.virtualisation.oci-containers.backend}-${s}.service") cfg.dependsOn);
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "10s";
            };
          }
        ];

        # Integrate with centralized Caddy reverse proxy if configured
        modules.services.caddy.virtualHosts.seerr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = seerrPort;
          };
          auth = cfg.reverseProxy.auth;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        # Backup integration using standardized restic pattern
        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          seerr = {
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
          serviceName = "seerr";
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
