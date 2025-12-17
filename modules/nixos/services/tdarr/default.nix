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
      default = "ghcr.io/haveagitgat/tdarr:2.58.02@sha256:20a5656c4af4854e1877046294f77113f949d27e35940a9a65f231423d063207";
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
      default = [ "/dev/dri" ];
      description = ''
        Device paths for hardware acceleration (VA-API /dev/dri).

        Default passes entire /dev/dri directory for robust device detection
        across reboots (device node numbers can change). The application will
        automatically select the correct render node.

        Common configurations:
        - Default (recommended): [ "/dev/dri" ]
        - Empty list: CPU-only transcoding

        For NVIDIA GPUs, additional nvidia-container-toolkit setup is required.
      '';
      example = [ "/dev/dri" ];
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

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach the container to.
        Enables DNS resolution between containers on the same network.
      '';
      example = "media-services";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "60s";
        timeout = "30s";
        retries = 3;
        startPeriod = "120s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure. Tdarr needs extra time to start MongoDB.";
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

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Tdarr transcoding automation failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Tdarr service events";
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
      tdarrWebPort = 8265;
      tdarrServerPort = 8266;
      mainServiceUnit = "${config.virtualisation.oci-containers.backend}-tdarr.service";
      datasetPath = "${storageCfg.datasets.parentDataset}/tdarr";

      # Look up the NFS mount configuration if a dependency is declared
      nfsMountName = cfg.nfsMountDependency;
      nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };

      # Build replication config for preseed (walks up dataset tree to find inherited config)
      replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

      hasCentralizedNotifications = config.modules.notifications.alertmanager.enable or false;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
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
          {
            assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
            message = "Tdarr preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
            message = "Tdarr preseed.enable requires preseed.passwordFile to be set.";
          }
        ];

        warnings =
          (lib.optional (cfg.reverseProxy == null) "Tdarr has no reverse proxy configured. Service will only be accessible locally.")
          ++ (lib.optional (cfg.backup == null) "Tdarr has no backup configured. Transcode profiles and database will not be protected.")
          ++ (lib.optional (cfg.accelerationDevices == [ ]) "Tdarr GPU passthrough is disabled. Transcoding will be CPU-only and slower.");

        # Create ZFS datasets for Tdarr configuration and cache
        modules.storage.datasets.services.tdarr = {
          mountpoint = cfg.dataDir;
          recordsize = "16K"; # Optimal for MongoDB database
          compression = "zstd";
          properties = {
            "com.sun:auto-snapshot" = "true";
          };
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        modules.storage.datasets.services.tdarr-cache = {
          mountpoint = cfg.transcodeCacheDir;
          recordsize = "1M"; # Optimal for large transcoding temp files
          compression = "off"; # Don't compress temporary transcode files
          properties = {
            "com.sun:auto-snapshot" = "false"; # Don't snapshot cache
            atime = "off";
          };
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        # Create system user for Tdarr
        users.users.tdarr = {
          uid = lib.mkDefault (lib.toInt cfg.user);
          group = cfg.group;
          isSystemUser = true;
          description = "Tdarr service user";
          # Add to render group for GPU access and media group for NFS access
          extraGroups = lib.optionals (cfg.accelerationDevices != [ ]) [ "render" ]
            ++ lib.optional (nfsMountName != null) cfg.mediaGroup;
        };

        # Create system group for Tdarr
        users.groups.tdarr = {
          gid = lib.mkDefault (lib.toInt cfg.user);
        };

        # Create subdirectories for Tdarr
        systemd.tmpfiles.rules = [
          "d ${cfg.dataDir}/server 0750 tdarr tdarr -"
          "d ${cfg.dataDir}/configs 0750 tdarr tdarr -"
          "d ${cfg.dataDir}/logs 0750 tdarr tdarr -"
        ];

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
          log-driver = "journald";
          extraOptions =
            (lib.optionals (cfg.accelerationDevices != [ ]) (
              map (dev: "--device=${dev}:${dev}:rwm") cfg.accelerationDevices
            ))
            ++ (lib.optionals (cfg.resources != null) [
              "--memory=${cfg.resources.memory}"
              "--memory-reservation=${cfg.resources.memoryReservation}"
              "--cpus=${cfg.resources.cpus}"
            ])
            ++ (lib.optionals (cfg.podmanNetwork != null) [
              "--network=${cfg.podmanNetwork}"
            ])
            ++ (lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
              "--health-cmd=curl --fail http://localhost:8265/api/v2/status || exit 1"
              "--health-interval=${cfg.healthcheck.interval}"
              "--health-timeout=${cfg.healthcheck.timeout}"
              "--health-retries=${toString cfg.healthcheck.retries}"
              "--health-start-period=${cfg.healthcheck.startPeriod}"
              "--health-on-failure=${cfg.healthcheck.onFailure}"
            ]);
        };

        # Systemd service dependencies and security
        systemd.services."${mainServiceUnit}" = lib.mkMerge [
          (lib.mkIf (cfg.podmanNetwork != null) {
            requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
            after = [ "podman-network-${cfg.podmanNetwork}.service" ];
          })
          {
            requires = [ "network-online.target" ]
              ++ lib.optional (nfsMountName != null) nfsMountConfig.mountUnitName;
            after = [ "network-online.target" ]
              ++ lib.optional (nfsMountName != null) nfsMountConfig.mountUnitName;
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "30s";
            };
          }
        ];

        # Integrate with centralized Caddy reverse proxy if configured
        modules.services.caddy.virtualHosts.tdarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = tdarrServerPort;
          };
          auth = cfg.reverseProxy.auth;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        # Backup integration using standardized restic pattern (ONLY config/database, NOT cache)
        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          tdarr = {
            enable = true;
            paths = [ cfg.dataDir ]; # Only backup config/database, not cache
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
          serviceName = "tdarr";
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
