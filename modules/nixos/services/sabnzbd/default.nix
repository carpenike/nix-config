{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

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

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach the container to.
        Enables DNS resolution between containers on the same network.
        This allows *arr services to resolve SABnzbd by container name.
      '';
      example = "media-services";
    };

    extraHostWhitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional hostnames to add to SABnzbd's `host_whitelist`.
        This is critical for allowing *arr services (running in other containers)
        to communicate with SABnzbd. Add your *arr container names here.
      '';
      example = [ "sonarr" "radarr" "readarr" "lidarr" ];
    };

    categories = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          dir = lib.mkOption {
            type = lib.types.str;
            description = ''
              Relative path from completed downloads directory where files for this category will be placed.
              This is relative to downloadsDir/complete/.
            '';
            example = "sonarr";
          };
          priority = lib.mkOption {
            type = lib.types.enum [ "-100" "0" "100" ];
            default = "0";
            description = ''
              Download priority for this category.
              -100 = Low, 0 = Normal, 100 = High
            '';
          };
        };
      });
      default = {
        sonarr = { dir = "sonarr"; priority = "0"; };
        radarr = { dir = "radarr"; priority = "0"; };
        readarr = { dir = "readarr"; priority = "0"; };
        lidarr = { dir = "lidarr"; priority = "0"; };
      };
      description = ''
        Pre-configured categories for SABnzbd.
        Unlike qBittorrent's dynamic categories, SABnzbd categories should be pre-configured
        as they control the final output directory via lookup rules.

        The *arr services pass a category string, and SABnzbd uses it to determine
        the final save path, making this a more centralized and robust configuration.
      '';
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
      description = "Reverse proxy configuration for SABnzbd web interface";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the SABnzbd API key.

        This option enables declarative API key management via sops-nix for consistency
        with other *arr services in the ecosystem. When set, the API key will be injected
        into SABnzbd's configuration at system activation time.

        If null (default), SABnzbd will generate a random API key on first run.
      '';
      example = "config.sops.secrets.\"sabnzbd/api-key\".path";
    };

    usenetProviders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Usenet provider hostname";
            example = "news-us.newsgroup.ninja";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 563;
            description = "Usenet provider port (563 for SSL, 119 for plain)";
          };
          connections = lib.mkOption {
            type = lib.types.int;
            default = 8;
            description = "Maximum number of connections to this server";
          };
          ssl = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Use SSL/TLS connection";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Server priority (0 = primary, higher = backup)";
          };
          retention = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Server retention in days (0 = unknown/unlimited)";
          };
          usernameFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Usenet username (via sops)";
          };
          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Usenet password (via sops)";
          };
        };
      });
      default = { };
      description = ''
        Declarative Usenet provider configuration.
        Credentials are managed via sops-nix for secure storage and disaster recovery.
      '';
      example = {
        newsgroup-ninja = {
          host = "news-us.newsgroup.ninja";
          port = 563;
          connections = 8;
          ssl = true;
          usernameFile = config.sops.secrets."sabnzbd/usenet/username".path;
          passwordFile = config.sops.secrets."sabnzbd/usenet/password".path;
        };
      };
    };

    # Critical operational settings (Gemini Pro analysis)
    fixedPorts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        CRITICAL: Force SABnzbd to use fixed ports instead of dynamic allocation.

        When enabled, SABnzbd will fail to start if its configured port is unavailable,
        rather than silently starting on an alternative port. This is essential for:
        - *arr service integration (they expect SABnzbd on a specific port)
        - Reverse proxy configuration
        - Firewall rules

        Disaster Recovery Impact: Without this, a port conflict during boot could cause
        SABnzbd to start on a different port, breaking all downstream automation.
      '';
    };

    enableHttpsVerification = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        SECURITY CRITICAL: Enable HTTPS certificate verification for outbound connections.

        When enabled, SABnzbd will validate SSL/TLS certificates for update checks,
        RSS feeds, and other external connections. Disabling this makes the application
        vulnerable to Man-in-the-Middle (MITM) attacks.

        Security Impact: Setting this to false allows attackers to intercept update
        checks and potentially serve malicious payloads.
      '';
    };

    cacheLimit = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = ''
        STABILITY CRITICAL: Article cache size limit (RAM allocation).

        This controls how much memory SABnzbd can use for caching downloaded articles
        before writing to disk. The value should be tuned based on available system RAM:
        - Systems with 4GB RAM: "512M"
        - Systems with 8GB RAM: "1G"
        - Systems with 16GB+ RAM: "2G" or higher

        Disaster Recovery Impact: Restoring to a system with insufficient RAM for the
        configured cache limit will cause OOM errors and application crashes.
      '';
      example = "2G";
    };

    bandwidthPercent = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = ''
        INTEGRATION RISK: Maximum bandwidth usage as percentage of available connection.

        Setting this to 100 will saturate the network link, which can:
        - Increase latency for *arr API calls, causing timeouts
        - Impact other services sharing the connection (Plex, SSH, etc.)
        - Cause health check failures

        Recommended: 80-90 for shared servers, 100 for dedicated download servers.

        Disaster Recovery Impact: Different network environments (10Gbps vs 100Mbps)
        require different bandwidth limits. This should be a conscious, declarative choice.
      '';
    };

    queueLimit = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = ''
        INTEGRATION: Maximum number of items allowed in download queue.

        The *arr applications can send large batches of downloads during backfills.
        If this limit is too low, excess downloads will be rejected and marked as failed,
        requiring manual intervention to re-grab them.

        Recommended: 20 for normal use, 50+ for large libraries with frequent backfills.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ 0 1 2 ];
      default = 1;
      description = ''
        OPERATIONAL: Logging verbosity level.
        - 0 = Error only
        - 1 = Info (recommended)
        - 2 = Debug (troubleshooting)

        Disaster Recovery Impact: Consistent logging is essential for debugging
        post-restore issues. Default Info level provides good visibility without
        excessive log volume.
      '';
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
          "**/*.log" # Exclude log files
          "**/cache/**" # Exclude cache directories
          "**/logs/**" # Exclude additional log directories
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
          scheme = "http"; # SABnzbd uses HTTP locally
          host = "127.0.0.1";
          port = cfg.port;
        };

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # PocketID / caddy-security configuration
        caddySecurity = cfg.reverseProxy.caddySecurity;

        # Security configuration from shared types
        security = cfg.reverseProxy.security;

        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Declare dataset requirements for per-service ZFS isolation
      # This integrates with the storage.datasets module to automatically
      # create tank/services/sabnzbd with appropriate ZFS properties
      modules.storage.datasets.services.sabnzbd = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite databases
        compression = "zstd"; # Better compression for text/config files
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable automatic snapshots
        };
        # Ownership matches the container user/group
        owner = cfg.user;
        group = cfg.group;
        mode = "0750"; # Allow group read access for backup systems
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
          UMASK = "002"; # Ensure group-writable files for *arr services to read
        };
        environmentFiles = lib.optionals (cfg.apiKeyFile != null) [
          # Inject API key via sops template for declarative secret management
          # Pattern matches *arr services (Sonarr/Radarr/Prowlarr)
          config.sops.templates."sabnzbd-env".path
        ];
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.downloadsDir}:/data:rw" # Unified mount point for hardlinks (TRaSH Guides best practice)
        ];
        ports = [
          "${toString cfg.port}:8080" # Map configurable host port to container port 8080
        ];
        resources = cfg.resources;
        extraOptions = [
          # Podman-level umask ensures container process creates files with group-writable permissions
          # This allows *arr services (in the same group) to move/hardlink files
          "--umask=0002" # Creates directories with 775 and files with 664
          "--pull=newer" # Automatically pull newer images
          # Force container to run as the specified user:group
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals (nfsMountConfig != null) [
          # Add media group to container so process can write to group-owned NFS mount
          "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          # Connect to Podman network for inter-container DNS resolution
          "--network=${cfg.podmanNetwork}"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Define the health check on the container itself
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/api?mode=version)" = 200 ]' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          # When unhealthy, take configured action (default: kill so systemd can restart)
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Config generator service - creates sabnzbd.ini with proper categories if missing
      systemd.services.sabnzbd-config-generator = {
        description = "Generate SABnzbd configuration if missing";
        before = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          # Load API key from sops template if configured
          EnvironmentFile = lib.mkIf (cfg.apiKeyFile != null) config.sops.templates."sabnzbd-env".path;
          ExecStart = pkgs.writeShellScript "generate-sab-config" ''
                      set -eu
                      CONFIG_FILE="${cfg.dataDir}/sabnzbd.ini"
                      CONFIG_DIR="${cfg.dataDir}"

                      # Only generate if config doesn't exist
                      if [ ! -f "$CONFIG_FILE" ]; then
                        echo "Config missing, generating from Nix settings..."
                        mkdir -p "$CONFIG_DIR"

                        # Read API key from environment if provided via sops
                        API_KEY_SETTING=""
                        if [ -n "''${SABNZBD__API_KEY:-}" ]; then
                          echo "Injecting API key from sops-nix..."
                          API_KEY_SETTING="api_key = $SABNZBD__API_KEY"
                        fi

                        # Generate declarative config with TRaSH Guides best practices
                        cat > "$CONFIG_FILE" << 'EOF'
            [misc]
            # === Basic Connection & Path Settings ===
            host = 0.0.0.0
            port = 8080
            download_dir = /data/sab/incomplete
            complete_dir = /data/sab/complete
            permissions = 0775
            # Create files with 664, directories with 775 for *arr service access
            umask = 002

            # === MUST HAVE SETTINGS (TRaSH Guides) ===
            # Security: Whitelist API access to specific hostnames
            # Add your *arr container names via extraHostWhitelist option
            host_whitelist = ${lib.concatStringsSep ", " (["sabnzbd" "localhost" "127.0.0.1"] ++ cfg.extraHostWhitelist)}

            # Security: Block potentially malicious file extensions
            unwanted_extensions = .ade, .adp, .app, .asp, .bas, .bat, .cer, .chm, .cmd, .com, .cpl, .crt, .csh, .der, .exe, .fxp, .gadget, .hlp, .hta, .inf, .ins, .isp, .its, .js, .jse, .ksh, .lnk, .mad, .maf, .mag, .mam, .maq, .mar, .mas, .mat, .mau, .mav, .maw, .mda, .mdb, .mde, .mdt, .mdw, .mdz, .msc, .msh, .msh1, .msh2, .msh1xml, .msh2xml, .mshxml, .msi, .msp, .mst, .ops, .pcd, .pif, .plg, .prf, .prg, .pst, .reg, .scf, .scr, .sct, .shb, .shs, .ps1, .ps1xml, .ps2, .ps2xml, .psc1, .psc2, .tmp, .url, .vb, .vbe, .vbs, .vsmacros, .vsw, .ws, .wsc, .wsf, .wsh, .xnk

            # *arr Integration: Unpack directly to final directory to enable hardlinks
            direct_unpack = 1

            # *arr Integration: Disable SABnzbd sorting - let *arrs manage priority
            enable_job_sorting = 0

            # Data Integrity: Only post-process verified downloads
            post_process_only_verified = 1

            # === RECOMMENDED DEFAULTS (TRaSH Guides) ===
            # Performance & Reliability
            allow_dupes = 0
            pause_on_post_processing = 1
            pre_check = 1
            queue_stalled_time = 300
            top_only = 1

            # Convenience
            enable_recursive_unpack = 1
            ignore_samples = 1
            nzb_backup_dir = /config/nzb-backup

            # === CRITICAL OPERATIONAL SETTINGS (Gemini Pro Analysis) ===
            # Stability: Force fixed ports to prevent silent port changes on boot
            fixed_ports = ${if cfg.fixedPorts then "1" else "0"}

            # Security: Enable HTTPS certificate verification (MITM protection)
            enable_https_verification = ${if cfg.enableHttpsVerification then "1" else "0"}

            # Performance: Article cache limit (tune based on system RAM)
            cache_limit = ${cfg.cacheLimit}

            # Integration: Bandwidth limit to prevent network saturation
            bandwidth_perc = ${toString cfg.bandwidthPercent}

            # Integration: Maximum queue size for *arr service bulk operations
            queue_limit = ${toString cfg.queueLimit}

            # Operational: Logging verbosity (0=Error, 1=Info, 2=Debug)
            log_level = ${toString cfg.logLevel}

            # Declaratively managed Usenet servers
            [servers]
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_name: server: ''
            [[${server.host}]]
            name = ${server.host}
            displayname = ${server.host}
            host = ${server.host}
            port = ${toString server.port}
            timeout = 60
            username = __USENET_USERNAME__
            password = __USENET_PASSWORD__
            connections = ${toString server.connections}
            ssl = ${if server.ssl then "1" else "0"}
            ssl_verify = 2
            ssl_ciphers = ""
            enable = 1
            required = 0
            optional = 0
            retention = ${toString server.retention}
            expire_date = ""
            quota = ""
            usage_at_start = 0
            priority = ${toString server.priority}
            '') cfg.usenetProviders)}

            # Pre-configured categories for *arr services
            # Categories control final output directory via lookup rules
            [categories]
            [[*]]
            name = *
            order = 0
            pp = 3
            script = None
            dir = ""
            priority = 0
            ${lib.concatStringsSep "\n" (lib.imap0 (idx: name:
              let catCfg = cfg.categories.${name}; in ''
            [[${name}]]
            name = ${name}
            order = ${toString (idx + 1)}
            pp = 3
            script = Default
            dir = ${catCfg.dir}
            priority = ${catCfg.priority}
            '') (lib.attrNames cfg.categories))}
            EOF

                        # Inject API key if provided via sops environment variable
                        if [ -n "''${SABNZBD__API_KEY:-}" ]; then
                          # Insert api_key under [misc] section (after first line)
                          sed -i '2i api_key = '"$SABNZBD__API_KEY" "$CONFIG_FILE"
                        fi

                        # Inject Usenet credentials if provided via sops environment variables
                        if [ -n "''${SABNZBD__USENET__USERNAME:-}" ] && [ -n "''${SABNZBD__USENET__PASSWORD:-}" ]; then
                          echo "Injecting Usenet credentials from sops-nix..."
                          sed -i "s/__USENET_USERNAME__/$SABNZBD__USENET__USERNAME/g" "$CONFIG_FILE"
                          sed -i "s/__USENET_PASSWORD__/$SABNZBD__USENET__PASSWORD/g" "$CONFIG_FILE"
                        fi

                        chmod 640 "$CONFIG_FILE"
                        echo "Configuration generated at $CONFIG_FILE"
                      else
                        echo "Config exists at $CONFIG_FILE, preserving existing file"
                      fi
          '';
        };
      };

      # Standardized systemd integration for container restart behavior
      systemd.services."${mainServiceUnit}" = lib.mkMerge [
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ "${config.virtualisation.oci-containers.backend}-media.mount" ]; # TODO: derive from nfsMountConfig.localPath
          after = [ "${config.virtualisation.oci-containers.backend}-media.mount" ];
        })
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
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
          # Wait for config generator and preseed service before starting container
          after = [ "sabnzbd-config-generator.service" ] ++ lib.optionals cfg.preseed.enable [
            "sabnzbd-preseed.service"
          ];
          wants = [ "sabnzbd-config-generator.service" ] ++ lib.optionals cfg.preseed.enable [
            "sabnzbd-preseed.service"
          ];
        }
      ];

      # NOTE: Health monitoring is now handled by Podman's native healthcheck timer
      # with --health-on-failure=kill to trigger systemd restart on unhealthy state.
      # The previous external systemd timer pattern is no longer needed.

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
        replicationCfg = replicationConfig; # Pass the auto-discovered replication config
        datasetProperties = {
          recordsize = "16K"; # Optimal for application data
          compression = "zstd"; # Better compression for config files
          "com.sun:auto-snapshot" = "true"; # Enable sanoid snapshots for this dataset
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
