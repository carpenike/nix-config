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

  cfg = config.modules.services.qbittorrent;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  qbittorrentPort = 8080; # WebUI port (internal to container)
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-qbittorrent.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/qbittorrent";
  configFile = "${cfg.dataDir}/qBittorrent/qBittorrent.conf";

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig =
    if nfsMountName != null
    then config.modules.storage.nfsMounts.${nfsMountName} or null
    else null;

  # Recursively find the replication config from the most specific dataset path upwards.
  # This allows a service dataset (e.g., tank/services/qbittorrent) to inherit replication
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
        # Get the suffix, e.g., "qbittorrent" from "tank/services/qbittorrent" relative to "tank/services"
        # Handle exact match case: if source path equals dataset path, suffix is empty
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/qbittorrent"
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
  options.modules.services.qbittorrent = {
    enable = lib.mkEnableOption "qbittorrent";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qbittorrent";
      description = "Path to qBittorrent data directory (config only)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "915";
      description = "User account under which qBittorrent runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media"; # shared media group (GID 65537)
      description = "Group under which qBittorrent runs.";
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
      default = "lscr.io/linuxserver/qbittorrent:5.0.2";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "5.0.2")
        - Use digest pinning for immutability (e.g., "5.0.2@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.

        When updating qBittorrent version, verify VueTorrent compatibility:
        https://github.com/VueTorrent/VueTorrent#compatibility
      '';
      example = "lscr.io/linuxserver/qbittorrent:5.0.2@sha256:f3ad4f59e6e5e4a...";
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

    torrentPort = lib.mkOption {
      type = lib.types.port;
      default = 6881;
      description = ''
        BitTorrent listening port (TCP and UDP).
        This is the port used for peer connections and DHT.
      '';
      example = 61144;
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

    macAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "02:42:ac:11:00:51";
      description = ''
        Static MAC address for the container.
        Required for stable IPv6 link-local addresses when binding to interface.
        Without this, qBittorrent will fail to start after container restart
        because it tries to bind to the old IPv6 link-local address.
      '';
      example = "02:42:ac:11:00:51";
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

    vuetorrent = {
      enable = lib.mkEnableOption "VueTorrent alternative WebUI";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.fetchzip {
          url = "https://github.com/VueTorrent/VueTorrent/releases/download/v2.31.0/vuetorrent.zip";
          hash = "sha256-4QJyTV6gDN/jZeG5108Ssuxpd4B/1cC7+V78SHU1xVk=";
          stripRoot = false;
        };
        description = ''
          VueTorrent package to mount into the container.

          Pinned to a specific version for reproducibility.
          Update the URL and hash together when upgrading.

          Check compatibility: https://github.com/VueTorrent/VueTorrent#compatibility
        '';
      };
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
      description = "Reverse proxy configuration for qBittorrent web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8080;
        path = "/api/v2/app/version";
        labels = {
          service_type = "download_client";
          exporter = "qbittorrent";
          function = "torrent";
        };
      };
      description = "Prometheus metrics collection configuration for qBittorrent";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-qbittorrent.service";
        labels = {
          service = "qbittorrent";
          service_type = "download_client";
        };
      };
      description = "Log shipping configuration for qBittorrent logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for qBittorrent configuration.

        qBittorrent stores configuration in a SQLite database and config files.
        Only the config directory is backed up - downloads are transient and excluded.

        Recommended settings:
        - useSnapshots: true (for SQLite consistency)
        - recordsize: 16K (optimal for SQLite)
      '';
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
            title = "qBittorrent Failed";
            body = "qBittorrent container has failed on ${config.networking.hostName}";
            priority = "critical";
          };
        };
      };
      description = "Notification channels and events for qBittorrent";
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

    settings = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (oneOf [ str int bool ]));
      default = {
        Application = {
          "FileLogger\\Enabled" = "true";
          "FileLogger\\Path" = "/config/qBittorrent/logs";
          "FileLogger\\MaxSizeBytes" = "66560";
          "FileLogger\\Age" = "1";
          "FileLogger\\AgeType" = "1";
          "FileLogger\\DeleteOld" = "true";
          "FileLogger\\Backup" = "true";
        };
        AutoRun = {
          enabled = "false";
          program = "";
        };
        BitTorrent = {
          "Session\\AddTorrentStopped" = "false";
          "Session\\AnonymousModeEnabled" = "true";
          "Session\\AsyncIOThreadsCount" = "10";
          "Session\\BTProtocol" = "TCP";
          # No predefined categories - let *arr services, tqm, and cross-seed create them as needed
          "Session\\DefaultSavePath" = "/data/qb/downloads/";
          "Session\\DHTEnabled" = "false";
          "Session\\DisableAutoTMMByDefault" = "false";
          "Session\\DiskCacheSize" = "-1";
          "Session\\DiskIOReadMode" = "DisableOSCache";
          "Session\\DiskIOType" = "SimplePreadPwrite";
          "Session\\DiskIOWriteMode" = "EnableOSCache";
          "Session\\DiskQueueSize" = "65536";
          "Session\\Encryption" = "0";
          "Session\\ExcludedFileNames" = "";
          "Session\\FilePoolSize" = "40";
          "Session\\GlobalDLSpeedLimit" = "81920";
          "Session\\HashingThreadsCount" = "2";
          "Session\\Interface" = "eth0";
          "Session\\LSDEnabled" = "false";
          "Session\\PeXEnabled" = "false";
          "Session\\Port" = toString cfg.torrentPort;
          "Session\\QueueingSystemEnabled" = "true";
          "Session\\ResumeDataStorageType" = "SQLite";
          "Session\\SSL\\Port" = "57024";
          "Session\\ShareLimitAction" = "Stop";
          # No predefined tags - let tqm, cross-seed, and other tools create them dynamically
          "Session\\TempPath" = "/data/qb/incomplete/";
          "Session\\UseAlternativeGlobalSpeedLimit" = "false";
          "Session\\UseOSCache" = "true";
          "Session\\UseRandomPort" = "false";
        };
        Core = {
          "AutoDeleteAddedTorrentFile" = "Never";
        };
        LegalNotice = {
          Accepted = "true";
        };
        Meta = {
          MigrationVersion = "8";
        };
        Network = {
          "PortForwardingEnabled" = "false";
          "Proxy\\HostnameLookupEnabled" = "false";
          "Proxy\\Profiles\\BitTorrent" = "true";
          "Proxy\\Profiles\\Misc" = "true";
          "Proxy\\Profiles\\RSS" = "true";
        };
        Preferences = {
          "Advanced\\AnonymousMode" = "true";
          "Advanced\\RecheckOnCompletion" = "false";
          "Advanced\\trackerPort" = "9000";
          "Advanced\\trackerPortForwarding" = "false";
          "Bittorrent\\DHT" = "false";
          "Bittorrent\\Encryption" = "0";
          "Bittorrent\\LSD" = "false";
          "Bittorrent\\PeX" = "false";
          "Connection\\PortRangeMin" = toString cfg.torrentPort;
          "Connection\\ResolvePeerCountries" = "true";
          "Connection\\UPnP" = "false";
          "Connection\\alt_speeds_on" = "false";
          "Downloads\\SavePath" = "/data/qb/downloads/";
          "Downloads\\TempPath" = "/data/qb/incomplete/";
          "General\\Locale" = "en";
          "General\\UseRandomPort" = "false";
          "Queueing\\MaxActiveDownloads" = "5";
          "Queueing\\MaxActiveTorrents" = "100";
          "Queueing\\MaxActiveUploads" = "10";
          "Queueing\\QueueingEnabled" = "true";
          "WebUI\\Address" = "*";
          "WebUI\\AlternativeUIEnabled" = "true";
          "WebUI\\AuthSubnetWhitelist" = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16";
          "WebUI\\AuthSubnetWhitelistEnabled" = "true";
          "WebUI\\CSRFProtection" = "false";
          "WebUI\\HostHeaderValidation" = "false";
          "WebUI\\LocalHostAuth" = "false";
          "WebUI\\Port" = "8080";
          "WebUI\\RootFolder" = "/vuetorrent";
          "WebUI\\ServerDomains" = "*";
          "WebUI\\SessionTimeout" = "3600";
          "WebUI\\UseUPnP" = "false";
        };
        RSS = {
          "AutoDownloader\\DownloadRepacks" = "true";
          "AutoDownloader\\SmartEpisodeFilter" = "s(\\\\d+)e(\\\\d+), (\\\\d+)x(\\\\d+), \"(\\\\d{4}[.\\\\-]\\\\d{1,2}[.\\\\-]\\\\d{1,2})\", \"(\\\\d{1,2}[.\\\\-]\\\\d{1,2}[.\\\\-]\\\\d{4})\"";
        };
      };
      description = ''
        Declarative settings for qBittorrent.conf.

        These settings are used to generate the configuration file on the first run
        or after the configuration file has been manually deleted.

        This "Declarative Initial Seeding" approach allows for:
        - Reproducible initial setup (version controlled in Git)
        - WebUI remains fully functional for runtime changes
        - Easy disaster recovery (delete config file, restart service)
        - Intentional updates (delete config to apply new Nix defaults)

        Note: Username and Password are not included here to avoid storing
        credentials in the Nix store. qBittorrent will use defaults on first
        run, which can then be changed through the WebUI.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Validate NFS mount dependency if specified
      assertions =
        (lib.optional (nfsMountName != null) {
          assertion = nfsMountConfig != null;
          message = "qBittorrent nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
        })
        ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "qBittorrent backup.enable requires backup.repository to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "qBittorrent preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "qBittorrent preseed.enable requires preseed.passwordFile to be set.";
        });

      # Auto-configure downloadsDir from NFS mount configuration
      modules.services.qbittorrent.downloadsDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      # Integrate with centralized Caddy reverse proxy if configured
      modules.services.caddy.virtualHosts.qbittorrent = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = {
          scheme = "http"; # qBittorrent uses HTTP locally
          host = "127.0.0.1";
          port = qbittorrentPort;
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
      # create tank/services/qbittorrent with appropriate ZFS properties
      modules.storage.datasets.services.qbittorrent = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite databases
        compression = "zstd"; # Better compression for text/config files
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable automatic snapshots
        };
        # Ownership matches the container user/group
        owner = "qbittorrent";
        group = "qbittorrent";
        mode = "0750"; # Allow group read access for backup systems
      };

      # Create local users to match container UIDs
      # This ensures proper file ownership on the host
      users.users.qbittorrent = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group; # Use configured group (defaults to "media")
        isSystemUser = true;
        description = "qBittorrent service user";
        # Add to media group for NFS access if dependency is set
        extraGroups = lib.optional (nfsMountName != null) cfg.mediaGroup;
      };

      # qBittorrent container configuration
      virtualisation.oci-containers.containers.qbittorrent = podmanLib.mkContainer "qbittorrent" {
        image = cfg.image;
        environment = {
          PUID = cfg.user;
          PGID = toString config.users.groups.${cfg.group}.gid; # Resolve group name to GID
          TZ = cfg.timezone;
          UMASK = "002"; # Ensure group-writable files for *arr services to read
          WEBUI_PORT = toString qbittorrentPort;
        };
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "${cfg.downloadsDir}:/data:rw" # Unified mount point for hardlinks (TRaSH Guides best practice)
        ] ++ lib.optionals cfg.vuetorrent.enable [
          "${cfg.vuetorrent.package}/vuetorrent:/vuetorrent:ro"
        ];
        ports = [
          "${toString qbittorrentPort}:${toString qbittorrentPort}"
          "${toString cfg.torrentPort}:${toString cfg.torrentPort}/tcp" # BitTorrent port
          "${toString cfg.torrentPort}:${toString cfg.torrentPort}/udp" # BitTorrent DHT port
        ];
        resources = cfg.resources;
        extraOptions = [
          # Podman-level umask ensures container process creates files with group-readable permissions
          # This allows restic-backup user (member of qbittorrent group) to read data
          "--umask=0027" # Creates directories with 750 and files with 640
          "--pull=newer" # Automatically pull newer images
          # Force container to run as the specified user:group
          "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
        ] ++ lib.optionals (cfg.macAddress != null) [
          # Static MAC address ensures stable IPv6 link-local address across restarts
          # Without this, qBittorrent fails to bind to the previous IPv6 address
          "--mac-address=${cfg.macAddress}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          # Attach to Podman network for DNS-based service discovery
          "--network=${cfg.podmanNetwork}"
        ] ++ lib.optionals (nfsMountConfig != null) [
          # Add media group to container so process can write to group-owned NFS mount
          "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
        ] ++ lib.optionals cfg.healthcheck.enable [
          # Define the health check on the container itself
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:${toString qbittorrentPort}/api/v2/app/version)" = 200 ]' ''
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
          requires = [ "${config.virtualisation.oci-containers.backend}-media.mount" ];
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
          # Generator runs before main service, checks if config missing
          # For manual config regeneration: rm /var/lib/qbittorrent/qBittorrent/qBittorrent.conf && systemctl restart qbittorrent-config-generator.service podman-qbittorrent.service
          wants = [ "qbittorrent-config-generator.service" ]
            ++ lib.optionals cfg.preseed.enable [ "qbittorrent-preseed.service" ];
          after = [ "qbittorrent-config-generator.service" ]
            ++ lib.optionals cfg.preseed.enable [ "qbittorrent-preseed.service" ];
        }
      ];

      # Declarative Initial Seeding: Generate config on-demand before service starts
      # Generator service is triggered by main service's wants/after dependencies

      # Config generator service - creates config only if missing
      # This preserves WebUI changes while ensuring correct initial configuration
      # To reset to Nix defaults: delete config file and restart this service
      systemd.services.qbittorrent-config-generator = {
        description = "Generate qBittorrent configuration if missing";
        before = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = pkgs.writeShellScript "generate-qb-config" ''
                      set -eu
                      CONFIG_FILE="${configFile}"
                      CONFIG_DIR=$(dirname "$CONFIG_FILE")

                      # Only generate if config doesn't exist
                      if [ ! -f "$CONFIG_FILE" ]; then
                        echo "Config missing, generating from Nix settings..."
                        mkdir -p "$CONFIG_DIR"

                        # Generate config using toINI
                        cat > "$CONFIG_FILE" << 'EOF'
            ${lib.generators.toINI {} cfg.settings}
            EOF

                        chmod 640 "$CONFIG_FILE"
                        echo "Configuration generated at $CONFIG_FILE"
                      else
                        echo "Config exists at $CONFIG_FILE, preserving existing file"
                      fi
          '';
        };
      };

      # Standardized health monitoring service
      systemd.services."qbittorrent-healthcheck" = lib.mkIf cfg.healthcheck.enable {
        description = "qBittorrent Health Check";
        after = [ mainServiceUnit ];
        requires = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.podman}/bin/podman healthcheck run qbittorrent";
          # Health checks should not restart the service
          Restart = "no";
        };
      };

      systemd.timers."qbittorrent-healthcheck" = lib.mkIf cfg.healthcheck.enable {
        description = "Timer for qBittorrent Health Check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnUnitActiveSec = cfg.healthcheck.interval;
          OnBootSec = cfg.healthcheck.startPeriod;
          Unit = "qbittorrent-healthcheck.service";
        };
      };

      # Notifications for service failures (centralized pattern)
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "qbittorrent-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: qBittorrent</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The qBittorrent torrent download client has entered a failed state.

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
        qbittorrent = {
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
        serviceName = "qbittorrent";
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
