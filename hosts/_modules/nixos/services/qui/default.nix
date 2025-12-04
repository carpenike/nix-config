{ lib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.qui;
  storageCfg = config.modules.storage;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-qui.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/qui";

  # Recursively find the replication config from the most specific dataset path upwards.
  # This allows a service dataset (e.g., tank/services/qui) to inherit replication
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
      else if parentPath != "" then
        findReplication parentPath
      else
        null;

  # Execute the search for the current service's dataset
  foundReplication = findReplication datasetPath;

  # Build the final config attrset to pass to the preseed service.
  # This only evaluates if replication is found and sanoid is enabled, preventing errors.
  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        # Get the suffix, e.g., "qui" from "tank/services/qui" relative to "tank/services"
        # Handle exact match case: if source path equals dataset path, suffix is empty
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/qui"
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
  options.modules.services.qui = {
    enable = lib.mkEnableOption "qui - Modern web interface for qBittorrent";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qui";
      description = ''
        Path to qui data directory.

        This directory stores:
        - config.toml (auto-generated on first run)
        - qui.db (SQLite database for state)
        - tracker-icons/ (cached tracker favicons)
        - logs (if logPath is configured)
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "980";
      description = "User account under which qui runs (numeric UID as string).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which qui runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/autobrr/qui:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.

        Multi-architecture support: linux/amd64, linux/arm64
      '';
      example = "ghcr.io/autobrr/qui:v1.7.0@sha256:abc...";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Podman network to attach the container to.

        Use "media-services" to enable DNS resolution to qBittorrent and other media services.
        Required for qui to act as a client proxy for Sonarr/Radarr/autobrr.
      '';
      example = "media-services";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7476;
      description = "Port for qui web interface";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = ''
        Host address to bind to.
        Use "0.0.0.0" for container environments (allows external access).
        Use "localhost" or "127.0.0.1" for local-only access.
      '';
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "/";
      description = ''
        Base URL path for serving qui from a subdirectory.

        Examples:
        - "/" for root domain (https://qui.example.com/)
        - "/qui/" for subdirectory (https://example.com/qui/)

        Must include trailing slash when using subdirectory.
      '';
      example = "/qui/";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "ERROR" "WARN" "INFO" "DEBUG" "TRACE" ];
      default = "INFO";
      description = "Logging level for qui";
    };

    metricsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Prometheus metrics endpoint.

        Metrics are served on a separate port (default: 9074) with optional basic auth.
        Includes torrent counts by status, transfer speeds, and instance health.
      '';
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9074;
      description = "Port for Prometheus metrics endpoint (when metricsEnabled = true)";
    };

    metricsHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address for metrics endpoint.
        Use "127.0.0.1" (recommended for security) or "0.0.0.0" if Prometheus runs externally.
      '';
    };

    oidc = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable OIDC single sign-on authentication";
          };

          issuer = lib.mkOption {
            type = lib.types.str;
            description = "OIDC issuer URL (e.g., https://auth.example.com/realms/main)";
          };

          clientId = lib.mkOption {
            type = lib.types.str;
            description = "OIDC client ID registered for qui";
          };

          clientSecretFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path to file containing OIDC client secret.
              Use SOPS or similar for secure secret management.

              SECURITY NOTE: This file will be mounted read-only at /run/secrets/oidc_client_secret
              inside the container. After the first run, you MUST manually edit config.toml in the
              data directory and set the 'client_secret' value under the [oidc] section to:
              "/run/secrets/oidc_client_secret"

              This application does not yet support reading secrets from files via environment
              variables (QUI__OIDC_CLIENT_SECRET_FILE pattern). This manual step prevents the
              secret from being exposed in container environment variables.
            '';
          };

          redirectUrl = lib.mkOption {
            type = lib.types.str;
            description = ''
              OIDC redirect URL - must match IdP configuration.
              Format: https://your-domain/api/auth/oidc/callback
              Include baseUrl if using subdirectory (e.g., https://host/qui/api/auth/oidc/callback)
            '';
          };

          disableBuiltInLogin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Hide local username/password login form when OIDC is enabled";
          };
        };
      });
      default = null;
      description = "OpenID Connect (OIDC) authentication configuration";
    };

    externalProgramAllowList = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ "/var/empty" ];
      description = ''
        Whitelist of executable paths allowed in torrent context menu external programs.

        Can include:
        - Direct paths to binaries: /usr/local/bin/sonarr
        - Directory paths (allows any executable inside): /home/user/bin

        SECURITY NOTE: The upstream application treats an empty list as "allow any path",
        which is insecure. This module defaults to a safe, non-existent path (/var/empty)
        to disable the feature. To use external programs, override this option with your
        desired executable paths.

        This setting is stored in config.toml which the UI cannot edit for security.
      '';
      example = [ "/usr/local/bin/sonarr" "/home/user/scripts" ];
    };

    checkForUpdates = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Check for qui updates on startup.
        Disable for air-gapped systems or when using container auto-updates.
      '';
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

        qui is lightweight but may consume more resources with:
        - Multiple qBittorrent instances
        - Large torrent collections (>1000 torrents)
        - Frequent backup operations
      '';
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
        default = "30s";
        description = "Grace period for container initialization.";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = ''
        Reverse proxy configuration for qui web interface.

        qui includes built-in client proxy feature that can:
        - Proxy qBittorrent API for Sonarr/Radarr/autobrr
        - Manage authentication automatically
        - Reduce qBittorrent login thrashing

        Configure proxy keys in qui UI after deployment.
      '';
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = ''
        Prometheus metrics collection configuration for qui.

        When qui.metricsEnabled = true, qui exposes metrics on qui.metricsPort.
        This option controls whether to register qui with Prometheus scraping.
      '';
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for qui container";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "qui qBittorrent web interface failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for qui service events";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for qui data.

        qui stores:
        - config.toml (configuration file)
        - qui.db (SQLite database with users, instances, proxy keys, API keys)
        - tracker-icons/ (cached favicon PNGs)

        Recommended recordsize: 16K (optimal for SQLite database)

        Note: qui has built-in qBittorrent backup/restore feature.
        This backup config is for qui's own state, not qBittorrent backups.
      '';
    };

    # NOTE: Dataset is managed via modules.storage.datasets.services.qui (declarative pattern).
    # This option is removed as it was unused - the module only checked for null/non-null.
    # Dataset configuration happens automatically when the service is enabled.

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

  config =
    let
      # Build environment variables
      environmentVars = {
        TZ = cfg.timezone;
        QUI__HOST = cfg.hostAddress;
        QUI__PORT = toString cfg.port;
        QUI__BASE_URL = cfg.baseUrl;
        QUI__LOG_LEVEL = cfg.logLevel;
        QUI__CHECK_FOR_UPDATES = if cfg.checkForUpdates then "true" else "false";
      } // lib.optionalAttrs cfg.metricsEnabled {
        QUI__METRICS_ENABLED = "true";
        QUI__METRICS_HOST = cfg.metricsHost;
        QUI__METRICS_PORT = toString cfg.metricsPort;
      } // lib.optionalAttrs (cfg.oidc != null && cfg.oidc.enabled) {
        QUI__OIDC_ENABLED = "true";
        QUI__OIDC_ISSUER = cfg.oidc.issuer;
        QUI__OIDC_CLIENT_ID = cfg.oidc.clientId;
        QUI__OIDC_REDIRECT_URL = cfg.oidc.redirectUrl;
        QUI__OIDC_DISABLE_BUILT_IN_LOGIN = if cfg.oidc.disableBuiltInLogin then "true" else "false";
      };

    in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        # Validate configuration
        assertions = [
          {
            assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
            message = "qui backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
          }
          {
            assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
            message = "qui preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = !cfg.preseed.enable || (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
            message = "qui preseed.enable requires preseed.passwordFile to be set.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.baseUrl;
            message = "qui baseUrl must be an absolute path starting with '/' (e.g., '/' or '/qui/').";
          }
          {
            assertion = cfg.baseUrl == "/" || lib.hasSuffix "/" cfg.baseUrl;
            message = "qui baseUrl must end with a trailing slash ('/') when using subdirectory paths (e.g., '/qui/').";
          }
          {
            assertion = let path = lib.removeSuffix "/" cfg.baseUrl; in path == "" || !lib.hasSuffix "/" path;
            message = "qui baseUrl contains redundant trailing slashes (e.g., '//' or '/qui//').";
          }
          {
            assertion = cfg.oidc == null || !cfg.oidc.enabled || (builtins.isPath cfg.oidc.clientSecretFile || builtins.isString cfg.oidc.clientSecretFile);
            message = "qui OIDC authentication requires oidc.clientSecretFile to be set.";
          }
          {
            assertion = cfg.oidc == null || !cfg.oidc.enabled || (cfg.oidc.issuer != "" && lib.hasPrefix "http" cfg.oidc.issuer);
            message = "qui OIDC authentication requires oidc.issuer to be a valid URL starting with 'http' (e.g., 'https://auth.example.com/realms/main').";
          }
          {
            assertion = cfg.oidc == null || !cfg.oidc.enabled || cfg.oidc.clientId != "";
            message = "qui OIDC authentication requires oidc.clientId to be set.";
          }
          {
            assertion = cfg.oidc == null || !cfg.oidc.enabled || (cfg.oidc.redirectUrl != "" && lib.hasPrefix "http" cfg.oidc.redirectUrl);
            message = "qui OIDC authentication requires oidc.redirectUrl to be a valid URL starting with 'http' (e.g., 'https://qui.example.com/api/auth/oidc/callback').";
          }
        ];

        # User configuration
        users.users.qui = {
          uid = lib.mkDefault (lib.toInt cfg.user);
          group = cfg.group;
          isSystemUser = true;
          description = "qui service user";
          home = cfg.dataDir;
          createHome = true;
        };

        users.groups.${cfg.group} = { };

        # Declare dataset requirements for per-service ZFS isolation
        # This integrates with the storage.datasets module to automatically
        # create tank/services/qui with appropriate ZFS properties
        # Note: OCI containers don't support StateDirectory, so we explicitly set permissions
        # via tmpfiles by keeping owner/group/mode here
        modules.storage.datasets.services.qui = {
          mountpoint = cfg.dataDir;
          recordsize = lib.mkDefault "16K"; # Optimal for SQLite databases (qui.db)
          compression = lib.mkDefault "lz4"; # Fast compression for database and config files
          properties = {
            "com.sun:auto-snapshot" = "true"; # Enable automatic snapshots
            # snapdir managed by sanoid module - no longer needed with clone-based backups
          };
          # Ownership matches the container user/group
          owner = cfg.user;
          group = cfg.group;
          mode = "0750"; # Allow group read access for backup systems
        };

        # NOTE: ZFS snapshots and replication for qui dataset should be configured
        # in the host-level config (e.g., hosts/forge/default.nix), not here.
        # Reason: Replication targets are host-specific (forge → nas-1, luna → nas-2, etc.)
        # Defining them in a shared module would hardcode "forge" in the target path,
        # breaking reusability across different hosts.

        # Note: Backup integration now handled by backup-integration module
        # The backup submodule configuration will be auto-discovered and converted
        # to a Restic job named "service-qui" with the specified settings

        # Container configuration
        virtualisation.oci-containers.containers.qui = podmanLib.mkContainer "qui" {
          image = cfg.image;
          autoStart = true;

          environment = environmentVars;

          # Use environmentFiles for OIDC client secret
          environmentFiles = lib.optionals (cfg.oidc != null && cfg.oidc.enabled) [
            config.sops.templates."qui-env".path
          ];

          volumes = [
            "${cfg.dataDir}:/config"
          ];

          ports = [
            "${toString cfg.port}:${toString cfg.port}"
          ] ++ lib.optionals cfg.metricsEnabled [
            "${cfg.metricsHost}:${toString cfg.metricsPort}:${toString cfg.metricsPort}"
          ];

          resources = cfg.resources;

          extraOptions = [
            "--pull=newer" # Automatically pull newer images
            "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
          ] ++ lib.optionals (cfg.podmanNetwork != null) [
            "--network=${cfg.podmanNetwork}"
          ] ++ lib.optionals cfg.healthcheck.enable [
            "--health-cmd=wget --no-verbose --tries=1 --spider http://localhost:${toString cfg.port}/health || exit 1"
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
          ];
        };

        # Apply additional service configuration
        systemd.services.${mainServiceUnit} = lib.mkMerge [
          {
            serviceConfig = {
              Restart = "always";
              RestartSec = "10s";
            };
            # Ensure SOPS secrets are available before qui starts
            # Prevents crash-loop when /run/qui-env doesn't exist yet
            requires = [ "sops-nix.service" ];
            after = [ "sops-nix.service" ];
          }
          (lib.mkIf (cfg.podmanNetwork != null) {
            requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
            after = [ "podman-network-${cfg.podmanNetwork}.service" ];
          })
        ];

        # Automatically register with Caddy reverse proxy if enabled
        modules.services.caddy.virtualHosts.qui = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;

          # Use structured backend configuration from shared types
          backend = {
            scheme = "http"; # qui uses HTTP locally
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

        # Note: Prometheus scrape config should be added manually in host configuration
        # Example:
        #   services.prometheus.scrapeConfigs = [{
        #     job_name = "qui";
        #     static_configs = [{ targets = [ "127.0.0.1:9074" ]; }];
        #   }];

        # Notifications integration
        modules.notifications.templates = lib.mkIf ((config.modules.notifications.enable or false) && cfg.notifications != null && cfg.notifications.enable) {
          "qui-failure" = {
            enable = lib.mkDefault true;
            priority = lib.mkDefault "high";
            title = lib.mkDefault ''<b><font color="red">✗ Service Failed: qui</font></b>'';
            body = lib.mkDefault ''
              <b>Host:</b> ''${hostname}
              <b>Service:</b> <code>''${serviceName}</code>

              The qui qBittorrent interface service has entered a failed state.

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
          serviceName = "qui";
          dataset = datasetPath;
          mountpoint = cfg.dataDir;
          mainServiceUnit = mainServiceUnit;
          replicationCfg = replicationConfig; # Pass the auto-discovered replication config
          datasetProperties = {
            recordsize = "16K"; # Optimal for SQLite databases
            compression = "zstd"; # Better compression for text/config files
            "com.sun:auto-snapshot" = "true"; # Enable sanoid snapshots for this dataset
          };
          resticRepoUrl = cfg.preseed.repositoryUrl;
          resticPasswordFile = cfg.preseed.passwordFile;
          resticEnvironmentFile = cfg.preseed.environmentFile;
          resticPaths = [ cfg.dataDir ];
          restoreMethods = cfg.preseed.restoreMethods;
          hasCentralizedNotifications = config.modules.notifications.enable or false;
          owner = cfg.user;
          group = cfg.group;
        }
      ))
    ];
}
