{ lib
, pkgs
, config
, ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.cross-seed;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  crossSeedPort = 2468;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-cross-seed.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/cross-seed";
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig = if nfsMountName != null then config.modules.storage.nfsMounts.${nfsMountName} or null else null;

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
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

  # Generate config.js from Nix attributes
  # Base configuration matching v6 format and best practices
  # See: https://www.cross-seed.org/docs/v6-migration
  baseConfig = {
    # Required fields for daemon mode
    delay = 30; # Seconds between searches (can be overridden in extraSettings)
    port = crossSeedPort;
    action = "inject"; # Inject torrents directly into qBittorrent

    # API authentication for webhook endpoint
    # Placeholder will be replaced with actual key from apiKeyFile at runtime
    apiKey = if cfg.apiKeyFile != null then "{{CROSS_SEED_API_KEY}}" else null;

    # Matching configuration (v6 options: "strict", "safe", "risky")
    # - strict: Exact file name and size matches only
    # - safe: Allows renames and slight inconsistencies (recommended default)
    # - risky: Most comprehensive, handles different file trees (formerly "partial")
    matchMode = "safe"; # Recommended default - prevents false positives

    # Torrent client configuration (populated by extraSettings)
    torrentClients = [ ]; # Format: ["type:http://user:pass@host:port"]
    useClientTorrents = true; # Use torrents from client for matching (recommended over torrentDir)

    # Directory configuration
    # CRITICAL: linkDirs CANNOT be inside outputDir, dataDirs, or torrentDir
    # Note: When dataDirs is set, dataDir is redundant and should be omitted
    # Note: When linkDirs is set, linkDir is redundant and should be omitted
    # Note: When useClientTorrents=true, torrentDir is not needed
    outputDir = null; # Set to null for action=inject (recommended by cross-seed - prevents unnecessary fallback saves)
    linkDirs = [ ]; # Will be populated by extraSettings - MUST be on same filesystem as dataDirs for hardlinks
    dataDirs = [ ]; # Will be populated by extraSettings (searches these directories)
    maxDataDepth = 1;

    # Indexer configuration (v6 format)
    # cross-seed v6 requires 'torznab' as an array of URLs (simplified from 'indexers')
    torznab = [ ]; # Will be populated by extraSettings with Prowlarr Torznab URLs

    # Content filtering (v6 format)
    # Note: includeEpisodes was REMOVED in v6 - use includeSingleEpisodes instead
    includeSingleEpisodes = true; # Include single episodes (not from season packs)
    includeNonVideos = true; # Include non-video content (music, books, etc.)

    # Linking configuration
    linkCategory = "cross-seed"; # Category for cross-seeded torrents
    linkType = "hardlink"; # Use hardlinks (recommended for same filesystem)
    duplicateCategories = true; # Allow multiple categories
    skipRecheck = true; # Skip recheck on injection (faster)

    # Season pack configuration
    seasonFromEpisodes = null; # Disable season packs from episodes (null = disabled)
  };

  mergedConfig = baseConfig // cfg.extraSettings;

  # Generate config.js using built-in JSON serialization
  # NOTE: JSON is a valid subset of JavaScript object literal syntax
  # Using builtins.toJSON is more robust than custom string concatenation
  # and properly handles special characters, escaping, and edge cases
  configJs = pkgs.writeText "config.js" ''
    module.exports = ${builtins.toJSON mergedConfig};
  '';
in
{
  options.modules.services.cross-seed = {
    enable = lib.mkEnableOption "cross-seed";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/cross-seed";
      description = "Path to cross-seed data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "921";
      description = "User account under which cross-seed runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which cross-seed runs.";
    };

    # NOTE: qbittorrentDataDir option removed - no longer needed with useClientTorrents=true
    # cross-seed uses the qBittorrent API directly instead of mounting BT_backup directory

    # This option is now automatically configured by nfsMountDependency
    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/media"; # Kept for standalone use, but will be overridden
      description = "Path to media library (qBittorrent downloads). Set automatically by nfsMountDependency.";
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
      default = "ghcr.io/cross-seed/cross-seed:6.13.6@sha256:e2bf5b593e4e7d699e6242423ad7966190cd52ba8eefafdfdbb0cb5b0b609b96";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Use Renovate bot to automate version updates
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Additional settings to merge into config.js.

        Example:
        {
          delay = 30;
          qbittorrentUrl = "http://127.0.0.1:8080";
          indexers = [
            {
              name = "prowlarr-indexer-1";
              torznab = "http://prowlarr:9696/1/api?apikey=...";
            }
          ];
        }
      '';
    };

    prowlarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing Prowlarr API key.
        If set, torznab URLs in extraSettings can use {{PROWLARR_API_KEY}} placeholder.
      '';
    };

    sonarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing Sonarr API key.
        If set, sonarr URLs in extraSettings can use {{SONARR_API_KEY}} placeholder.
      '';
    };

    radarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing Radarr API key.
        If set, radarr URLs in extraSettings can use {{RADARR_API_KEY}} placeholder.
      '';
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to file containing cross-seed API key for webhook authentication.
        This key must be provided by Sonarr/Radarr in the X-Api-Key header when calling the webhook endpoint.
        If set, the {{CROSS_SEED_API_KEY}} placeholder in extraSettings will be replaced.
      '';
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
        description = "Grace period for container initialization.";
      };
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for cross-seed web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 2468;
        path = "/metrics";
        labels = {
          service_type = "media_automation";
          exporter = "cross-seed";
          function = "cross_seeding";
        };
      };
      description = "Prometheus metrics collection configuration (native /metrics endpoint)";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-cross-seed.service";
        labels = {
          service = "cross-seed";
          service_type = "media_tools";
        };
      };
      description = "Logging configuration for cross-seed";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "cross-seed" "config" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/cross-seed";
      };
      description = "Backup configuration for cross-seed";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "cross-seed automatic cross-seeding failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for cross-seed service events";
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
          Order and selection of restore methods to attempt.
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
          message = "cross-seed nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "cross-seed preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "cross-seed preseed.enable requires preseed.passwordFile to be set.";
        });

      # Automatically set mediaDir from the NFS mount configuration
      modules.services.cross-seed.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      users.groups.${cfg.group} = lib.mkIf (cfg.group == "media") {
        gid = 65537; # Shared media group (993 was taken by alertmanager)
      };

      users.users.cross-seed = {
        isSystemUser = true;
        uid = lib.toInt cfg.user;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = false;
        description = "cross-seed automatic cross-seeding daemon";
      };

      # Configure ZFS dataset with appropriate properties
      # Note: OCI containers don't support StateDirectory, so we explicitly set permissions
      # via tmpfiles by keeping owner/group/mode here
      modules.storage.datasets.services.cross-seed = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for configuration and small files
        compression = "zstd"; # Better compression for text/config files
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable automatic snapshots
        };
        # Ownership matches the container user/group
        owner = "cross-seed";
        group = cfg.group;
        mode = "0750"; # Allow group read access for backup systems
      };

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.cross-seed = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = crossSeedPort;
        };

        auth = cfg.reverseProxy.auth;
        authelia = cfg.reverseProxy.authelia;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Ensure subdirectories exist with proper permissions
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
        "d '${cfg.dataDir}/data' 0750 ${cfg.user} ${cfg.group} - -"
        # NOTE: output directory removed - outputDir is null for action=inject mode
      ];

      # Configuration file generation service
      systemd.services."cross-seed-config" = {
        description = "Generate cross-seed configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ mainServiceUnit ];
        after = [ "var-lib-cross\\x2dseed.mount" ];
        requires = [ "var-lib-cross\\x2dseed.mount" ];
        script = ''
          mkdir -p ${cfg.dataDir}/data
          # NOTE: output directory removed - outputDir is null for action=inject mode

          # Copy config.js to the root of dataDir (will be /config/config.js in container)
          cp ${configJs} ${cfg.dataDir}/config.js

          ${lib.optionalString (cfg.prowlarrApiKeyFile != null) ''
            # Substitute Prowlarr API key placeholder with actual key from secret file
            if [ -f "${cfg.prowlarrApiKeyFile}" ]; then
              PROWLARR_API_KEY=$(cat "${cfg.prowlarrApiKeyFile}")
              ${pkgs.gnused}/bin/sed -i "s|{{PROWLARR_API_KEY}}|$PROWLARR_API_KEY|g" ${cfg.dataDir}/config.js
            fi
          ''}

          ${lib.optionalString (cfg.sonarrApiKeyFile != null) ''
            # Substitute Sonarr API key placeholder with actual key from secret file
            if [ -f "${cfg.sonarrApiKeyFile}" ]; then
              SONARR_API_KEY=$(cat "${cfg.sonarrApiKeyFile}")
              ${pkgs.gnused}/bin/sed -i "s|{{SONARR_API_KEY}}|$SONARR_API_KEY|g" ${cfg.dataDir}/config.js
            fi
          ''}

          ${lib.optionalString (cfg.radarrApiKeyFile != null) ''
            # Substitute Radarr API key placeholder with actual key from secret file
            if [ -f "${cfg.radarrApiKeyFile}" ]; then
              RADARR_API_KEY=$(cat "${cfg.radarrApiKeyFile}")
              ${pkgs.gnused}/bin/sed -i "s|{{RADARR_API_KEY}}|$RADARR_API_KEY|g" ${cfg.dataDir}/config.js
            fi
          ''}

          ${lib.optionalString (cfg.apiKeyFile != null) ''
            # Substitute cross-seed API key placeholder with actual key from secret file
            if [ -f "${cfg.apiKeyFile}" ]; then
              CROSS_SEED_API_KEY=$(cat "${cfg.apiKeyFile}")
              ${pkgs.gnused}/bin/sed -i "s|{{CROSS_SEED_API_KEY}}|$CROSS_SEED_API_KEY|g" ${cfg.dataDir}/config.js
            fi
          ''}

          chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
          chmod 0640 ${cfg.dataDir}/config.js
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };

      # Add systemd dependencies for the container service
      # Add systemd dependencies
      systemd.services."${config.virtualisation.oci-containers.backend}-cross-seed" = lib.mkMerge [
        {
          after = [ "cross-seed-config.service" "var-lib-cross\\x2dseed.mount" ];
          requires = [ "var-lib-cross\\x2dseed.mount" ];
          wants = [ "cross-seed-config.service" ];
        }
        # Add NFS mount dependency if configured
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ nfsMountConfig.mountUnitName ];
          after = [ nfsMountConfig.mountUnitName ];
        })
        # Add Podman network dependency if configured
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        # Add failure notifications via systemd
        (lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@cross-seed-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-cross-seed.service" ];
          after = [ "preseed-cross-seed.service" ];
        })
      ];

      # Container service
      virtualisation.oci-containers.containers.cross-seed = {
        image = cfg.image;
        autoStart = true;
        user = "${cfg.user}:${toString config.users.groups.${cfg.group}.gid}";
        cmd = [ "daemon" ];
        environment = {
          PUID = cfg.user;
          PGID = toString config.users.groups.${cfg.group}.gid;
          TZ = cfg.timezone;
        };
        volumes = [
          "/var/lib/cross-seed:/config"
          # Mount NFS share only when nfsMountDependency is configured (hybrid filesystem+API mode)
          # In pure API mode (nfsMountDependency = null), no media mount needed
        ] ++ lib.optionals (cfg.nfsMountDependency != null) [
          "${cfg.mediaDir}:/data" # Unified mount point for hardlinks (TRaSH Guides best practice)
          # NOTE: outputDir is set to null in config.js for action=inject mode
          # No /output volume mount needed - torrents go directly to qBittorrent via API
          # NOTE: qBittorrent's BT_backup directory is NOT mounted here.
          # With useClientTorrents=true (set in config.js), cross-seed uses the qBittorrent API
          # directly and does not need filesystem access to .torrent files.
          # This mount was deprecated in cross-seed v6.9.0+
        ];
        ports = [
          "127.0.0.1:${toString crossSeedPort}:${toString crossSeedPort}"
        ];
        extraOptions = [
          "--pull=newer"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          # Attach to Podman network for DNS-based service discovery
          "--network=${cfg.podmanNetwork}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          # Health check using /api/ping endpoint (returns 200 when healthy)
          # This is the proper health check endpoint used in Kubernetes deployments
          ''--health-cmd=curl -f http://localhost:${toString crossSeedPort}/api/ping''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      systemd.services.${mainServiceUnit} = {
        after = [ "cross-seed-config.service" ];
        requires = [ "cross-seed-config.service" ];
      };

    })

    # Preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "cross-seed";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "lz4";
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
