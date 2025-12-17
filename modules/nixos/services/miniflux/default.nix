# NixOS module for Miniflux RSS Reader
#
# This module wraps the native services.miniflux NixOS module with homelab-specific
# integrations following ADR-005 (Native Services Over Containers):
# - ZFS persistence with auto-snapshot
# - Native OIDC authentication via PocketID
# - Caddy reverse proxy integration
# - Prometheus metrics exposure
# - Preseed for disaster recovery
# - Homepage and Gatus contributions
#
# Miniflux is a minimalist and opinionated RSS feed reader that uses PostgreSQL.
# The native module handles database provisioning via createDatabaseLocally.
#
{ config, lib, mylib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types optionals optionalAttrs;
  cfg = config.modules.services.miniflux;
  serviceName = "miniflux";

  # Import shared type definitions
  sharedTypes = mylib.types;

  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  # Define storage configuration for consistent access
  storageCfg = config.modules.storage;

  # Construct the dataset path for miniflux
  datasetPath = "${storageCfg.datasets.parentDataset}/miniflux";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Check if PocketID is available
  pocketIdEnabled = config.modules.services.pocketid.enable or false;
  oidcProviderName = if pocketIdEnabled then "Pocket ID" else "SSO";

  # Build the listen address for Miniflux
  listenAddr = "${cfg.listenAddress}:${toString cfg.port}";
in
{
  options.modules.services.miniflux = {
    enable = mkEnableOption "Miniflux RSS reader";

    package = mkOption {
      type = types.package;
      default = pkgs.miniflux;
      description = "The Miniflux package to use";
    };

    port = mkOption {
      type = types.port;
      default = 8381;
      description = ''
        Port for Miniflux to listen on.
        Changed from upstream default (8080) to avoid conflict with qbittorrent.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for Miniflux to listen on";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/miniflux";
      description = "Directory to store Miniflux state (primarily database socket path)";
    };

    # Database configuration
    # Miniflux uses PostgreSQL - the native module can auto-provision
    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to create the PostgreSQL database locally.
          When enabled, uses the native services.miniflux.createDatabaseLocally option.
        '';
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          PostgreSQL connection URL. Only used when createLocally is false.
          Example: "postgres://user:pass@host/dbname?sslmode=disable"
        '';
      };
    };

    # Admin credentials - used for initial admin user creation
    adminCredentials = {
      enable = mkEnableOption "Create admin user from credentials file";

      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing ADMIN_USERNAME and ADMIN_PASSWORD in
          environment file format. Managed by SOPS.
          Format:
            ADMIN_USERNAME=admin
            ADMIN_PASSWORD=secretpassword
        '';
      };
    };

    # OIDC authentication configuration (following Paperless/Grafana patterns)
    oidc = {
      enable = mkEnableOption "OIDC authentication via PocketID or other provider";

      discoveryEndpoint = mkOption {
        type = types.str;
        default = "";
        example = "https://id.example.com";
        description = ''
          OIDC discovery endpoint URL (without .well-known/openid-configuration).
          For PocketID: https://id.yourdomain.com
        '';
      };

      clientId = mkOption {
        type = types.str;
        default = "miniflux";
        description = "OIDC client ID";
      };

      clientSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing OIDC client secret (SOPS managed)";
      };

      redirectUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://miniflux.example.com/oauth2/oidc/callback";
        description = ''
          OAuth2 redirect URL. Must be registered with the OIDC provider.
          If empty, will be auto-generated from reverseProxy.hostName.
        '';
      };

      providerName = mkOption {
        type = types.str;
        default = oidcProviderName;
        description = "Display name for the OIDC provider on the login page";
      };

      userCreation = mkOption {
        type = types.bool;
        default = true;
        description = "Allow automatic user creation on first OIDC login";
      };

      disableLocalAuth = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Disable local authentication (username/password).
          When enabled, only OIDC login is available.
          Note: Keep disabled initially to link existing admin account to OIDC.
        '';
      };
    };

    # Prometheus metrics
    metricsCollector = {
      enable = mkEnableOption "Prometheus metrics collector at /metrics";

      allowedNetworks = mkOption {
        type = types.listOf types.str;
        default = [ "127.0.0.1/8" "10.0.0.0/8" ];
        description = "Networks allowed to access the /metrics endpoint";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Miniflux web interface";
    };

    # Standardized metrics collection pattern
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8381;
        path = "/metrics";
        labels = {
          service_type = "rss_reader";
          exporter = "miniflux";
          function = "feed_aggregation";
        };
      };
      description = "Prometheus metrics collection configuration for Miniflux";
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "miniflux.service";
        labels = {
          service = "miniflux";
          service_type = "rss_reader";
        };
      };
      description = "Log shipping configuration for Miniflux logs";
    };

    # Standardized notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "productivity-alerts" ];
        };
        customMessages = {
          failure = "Miniflux RSS reader failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Miniflux service events";
    };

    # Consistent submodule for ZFS
    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/miniflux";
        description = "ZFS dataset to mount at dataDir";
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        description = "ZFS dataset properties";
      };
    };

    # Preseed configuration for disaster recovery
    preseed = {
      enable = mkEnableOption "automatic data restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
          Note: restic is intentionally excluded by default per preseed policy.
        '';
      };
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "productivity" "miniflux" "rss" ];
        useSnapshots = true;
        zfsDataset = "tank/services/miniflux";
        excludePatterns = [
          "**/sessions/*"
        ];
      };
      description = "Backup configuration for Miniflux";
    };

    # Standardized systemd resource management
    resources = mkOption {
      type = sharedTypes.systemdResourcesSubmodule;
      default = {
        MemoryMax = "256M";
        MemoryReservation = "64M";
        CPUQuota = "25%";
      };
      description = "Systemd resource limits for Miniflux service";
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable (
      let
        # Build the OIDC redirect URL if not explicitly set
        oidcRedirectUrl =
          if cfg.oidc.redirectUrl != ""
          then cfg.oidc.redirectUrl
          else if cfg.reverseProxy != null && cfg.reverseProxy.enable
          then "https://${cfg.reverseProxy.hostName}/oauth2/oidc/callback"
          else "";

        # Build the base URL for Miniflux
        baseUrl =
          if cfg.reverseProxy != null && cfg.reverseProxy.enable
          then "https://${cfg.reverseProxy.hostName}"
          else "http://localhost:${toString cfg.port}";
      in
      {
        # Enable the native NixOS Miniflux module
        services.miniflux = {
          enable = true;
          package = cfg.package;

          # Database configuration
          createDatabaseLocally = cfg.database.createLocally;

          # Admin credentials file (if provided)
          adminCredentialsFile = cfg.adminCredentials.credentialsFile;

          # Miniflux configuration via environment variables
          config = {
            LISTEN_ADDR = listenAddr;
            BASE_URL = baseUrl;
            RUN_MIGRATIONS = 1;

            # Enable Prometheus metrics
            METRICS_COLLECTOR = if cfg.metricsCollector.enable then 1 else 0;
            METRICS_ALLOWED_NETWORKS = lib.concatStringsSep "," cfg.metricsCollector.allowedNetworks;

            # Enable systemd watchdog for reliability
            WATCHDOG = 1;
          }
          // optionalAttrs (cfg.database.url != null && !cfg.database.createLocally) {
            DATABASE_URL = cfg.database.url;
          }
          // optionalAttrs cfg.oidc.enable {
            OAUTH2_PROVIDER = "oidc";
            OAUTH2_CLIENT_ID = cfg.oidc.clientId;
            OAUTH2_OIDC_DISCOVERY_ENDPOINT = cfg.oidc.discoveryEndpoint;
            OAUTH2_REDIRECT_URL = oidcRedirectUrl;
            OAUTH2_USER_CREATION = if cfg.oidc.userCreation then 1 else 0;
            OAUTH2_OIDC_PROVIDER_NAME = cfg.oidc.providerName;
            DISABLE_LOCAL_AUTH = if cfg.oidc.disableLocalAuth then 1 else 0;
          }
          // optionalAttrs (cfg.oidc.enable && cfg.oidc.clientSecretFile != null) {
            # Miniflux reads the secret from this file path
            OAUTH2_CLIENT_SECRET_FILE = cfg.oidc.clientSecretFile;
          }
          // optionalAttrs cfg.adminCredentials.enable {
            CREATE_ADMIN = 1;
          };
        };

        # Apply systemd hardening, resource limits, and OIDC secret loading
        systemd.services.miniflux = {
          serviceConfig = {
            # Override DynamicUser for stable UID (required for ZFS ownership and SOPS secrets)
            # Following gatus pattern per service-module.prompt.md
            DynamicUser = lib.mkForce false;
            User = serviceName;
            Group = serviceName;

            # Resource limits
            MemoryMax = cfg.resources.MemoryMax;
            MemoryReservation = cfg.resources.MemoryReservation;
            CPUQuota = cfg.resources.CPUQuota;

            # Security hardening (supplement native module)
            ProtectSystem = lib.mkDefault "strict";
            ProtectHome = lib.mkDefault true;
            PrivateTmp = lib.mkDefault true;
            PrivateDevices = lib.mkDefault true;
            ProtectKernelTunables = lib.mkDefault true;
            ProtectKernelModules = lib.mkDefault true;
            ProtectControlGroups = lib.mkDefault true;
            NoNewPrivileges = lib.mkDefault true;
          };

          # Service dependencies for ZFS dataset mounting and preseed
          after =
            optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ]
            ++ optionals cfg.preseed.enable [ "preseed-miniflux.service" ];
          wants =
            optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ]
            ++ optionals cfg.preseed.enable [ "preseed-miniflux.service" ];
        };

        # Create miniflux user/group with stable UID (required for secrets)
        users.users.${serviceName} = {
          isSystemUser = true;
          group = serviceName;
          home = lib.mkForce "/var/empty";
          description = "Miniflux RSS reader service user";
        };

        users.groups.${serviceName} = { };

        # ZFS dataset configuration (if enabled)
        modules.storage.datasets.services.${serviceName} = mkIf (cfg.zfs.dataset != null) {
          mountpoint = cfg.dataDir;
          recordsize = "16K"; # Good for database workload (PostgreSQL socket path)
          compression = "zstd";
          properties = cfg.zfs.properties;
          owner = serviceName;
          group = serviceName;
          mode = "0750";
        };

        # Automatically register with Caddy reverse proxy
        modules.services.caddy.virtualHosts.miniflux = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;

          # Use structured backend configuration from shared types
          backend = cfg.reverseProxy.backend or {
            host = cfg.listenAddress;
            port = cfg.port;
          };

          # Authentication - Miniflux has native OIDC, no caddySecurity needed
          auth = cfg.reverseProxy.auth or null;

          # Security configuration from shared types
          security = (cfg.reverseProxy.security or { }) // {
            customHeaders = ((cfg.reverseProxy.security or { }).customHeaders or { }) // {
              "X-Frame-Options" = "SAMEORIGIN";
              "X-Content-Type-Options" = "nosniff";
              "X-XSS-Protection" = "1; mode=block";
            };
          };

          # Cloudflare Tunnel configuration - set via host config in the guard block
          # (e.g., modules.services.caddy.virtualHosts.miniflux.cloudflare = {...})

          # Additional configuration
          extraConfig = cfg.reverseProxy.extraConfig or "";
        };

        # Validations
        assertions = [
          {
            assertion = cfg.oidc.enable -> cfg.oidc.discoveryEndpoint != "";
            message = "Miniflux OIDC requires discoveryEndpoint to be set.";
          }
          {
            assertion = cfg.oidc.enable -> cfg.oidc.clientSecretFile != null;
            message = "Miniflux OIDC requires clientSecretFile to be set.";
          }
          {
            assertion = cfg.preseed.enable -> cfg.preseed.repositoryUrl != "";
            message = "Miniflux preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = cfg.preseed.enable -> cfg.preseed.passwordFile != null;
            message = "Miniflux preseed.enable requires preseed.passwordFile to be set.";
          }
        ];
      }
    ))

    # Add the preseed service itself
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "miniflux";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "miniflux.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          compression = "zstd";
          atime = "off";
        } // cfg.zfs.properties;
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = true;
        owner = "miniflux";
        group = "miniflux";
      }
    ))
  ];
}
