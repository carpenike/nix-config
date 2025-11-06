# NixOS module for Grafana
#
# This module provides a declarative and modular way to configure Grafana,
# consistent with other services in this homelab configuration. It includes
# support for:
# - ZFS persistence
# - Caddy reverse proxy with authentication
# - SOPS for secret management
# - Declarative provisioning of plugins, datasources, and dashboards
# - Automatic discovery of Loki and Prometheus services
#
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mapAttrsToList;
  cfg = config.modules.services.grafana;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Import storage helpers for preseed service generation
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  # Define storage configuration for consistent access
  storageCfg = config.modules.storage;

  # Construct the dataset path for grafana
  datasetPath = "${storageCfg.datasets.parentDataset}/grafana";

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    let
      sanoidDatasets = config.modules.backup.sanoid.datasets;
      replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
    in
    if replicationInfo != null then
      {
        sourcePath = dsPath;
        replication = replicationInfo;
      }
    else
      let
        parts = lib.splitString "/" dsPath;
        parentPath = lib.concatStringsSep "/" (lib.init parts);
      in
      if parentPath == "" || parts == [] then
        null
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  # Compute replication config for preseed service
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
in
{
  ###### Options

  options.modules.services.grafana = {
    enable = mkEnableOption "Grafana monitoring service";

    package = mkOption {
      type = types.package;
      default = pkgs.grafana;
      description = "The Grafana package to use";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Port for Grafana to listen on";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for Grafana to listen on";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/grafana";
      description = "Directory to store Grafana's database and other state";
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Grafana web interface";
    };

    # Standardized metrics collection pattern
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 3000;
        path = "/metrics";
        labels = {
          service_type = "monitoring";
          exporter = "grafana";
          function = "visualization";
        };
      };
      description = "Prometheus metrics collection configuration for Grafana";
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "grafana.service";
        labels = {
          service = "grafana";
          service_type = "monitoring";
        };
      };
      description = "Log shipping configuration for Grafana logs";
    };

    # Standardized notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "monitoring-alerts" ];
        };
        customMessages = {
          failure = "Grafana monitoring dashboard failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Grafana service events";
    };

    # Consistent submodule for ZFS
    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/grafana";
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
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
        '';
      };
    };

    # Standardized systemd resource management
    resources = mkOption {
      type = sharedTypes.systemdResourcesSubmodule;
      default = {
        MemoryMax = "1G";
        MemoryReservation = "512M";
        CPUQuota = "50%";
      };
      description = "Systemd resource limits for Grafana service";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "monitoring" "grafana" "dashboards" ];
        useSnapshots = true;
        zfsDataset = "tank/services/grafana";
        # ZFS snapshots provide consistency - backup the live database
        # SQLite is resilient to point-in-time copies via ZFS snapshots
        excludePatterns = [
          "**/sessions/*"    # Exclude session data
          "**/png/*"         # Exclude rendered images
          "**/csv/*"         # Exclude CSV exports
          "**/pdf/*"         # Exclude PDF exports
        ];
      };
      description = "Backup configuration for Grafana";
    };

    # Grafana-specific settings
    secrets = {
      adminUser = mkOption {
        type = types.str;
        default = "admin";
        description = "Initial admin user name";
      };

      adminPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to a file containing the initial admin password (managed by SOPS)";
      };
    };

    # OIDC/OAuth authentication
    oidc = {
      enable = mkEnableOption "OIDC authentication";

      clientId = mkOption {
        type = types.str;
        default = "grafana";
        description = "OIDC client ID";
      };

      clientSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing OIDC client secret";
      };

      authUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://auth.example.com/api/oidc/authorization";
        description = "OIDC authorization endpoint";
      };

      tokenUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://auth.example.com/api/oidc/token";
        description = "OIDC token endpoint";
      };

      apiUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://auth.example.com/api/oidc/userinfo";
        description = "OIDC userinfo endpoint";
      };

      scopes = mkOption {
        type = types.listOf types.str;
        default = [ "openid" "profile" "email" "groups" ];
        description = "OAuth scopes to request";
      };

      roleAttributePath = mkOption {
        type = types.str;
        default = "contains(groups[*], 'admins') && 'Admin' || 'Viewer'";
        description = "JMESPath expression to map groups to Grafana roles";
      };

      allowSignUp = mkOption {
        type = types.bool;
        default = true;
        description = "Allow users to sign up via OIDC";
      };

      signoutRedirectUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://auth.example.com/logout";
        description = "URL to redirect to after logout (for OIDC logout)";
      };
    };

    # Declarative Provisioning
    provisioning = {
      plugins = mkOption {
        type = with types; listOf package;
        default = [];
        example = lib.literalExpression "with pkgs.grafanaPlugins; [ grafana-worldmap-panel ]";
        description = "List of Grafana plugins to install";
      };

      datasources = mkOption {
        type = types.attrs;
        default = {};
        description = ''
          Attribute set of data sources to provision.
          User-defined sources will override auto-configured ones with the same name.
        '';
      };

      dashboards = mkOption {
        type = with types; attrsOf (submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Unique name for the dashboard provider";
            };
            folder = mkOption {
              type = types.str;
              default = "";
              description = "Folder to store dashboards in Grafana UI";
            };
            path = mkOption {
              type = types.path;
              description = "Path to a directory containing dashboard JSON files";
            };
          };
        });
        default = {};
        description = "Attribute set of dashboard providers to provision";
      };
    };

    # Logic for integrating with other services
    autoConfigure = {
      loki = mkEnableOption "automatic configuration of the Loki data source";
      prometheus = mkEnableOption "automatic configuration of the Prometheus data source";
    };
  };

  ###### Implementation

  config = lib.mkMerge [
    (mkIf cfg.enable (
    let
      # Auto-generate Loki data source if enabled and the Loki module is active
      lokiDataSource = if (cfg.autoConfigure.loki && (config.modules.services.loki.enable or false)) then {
        "loki-auto" = {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://${config.modules.services.loki.listenAddress or "127.0.0.1"}:${toString (config.modules.services.loki.port or 3100)}";
          isDefault = false;
        };
      } else {};

      # Auto-generate Prometheus data source if enabled and the Prometheus service is available
      prometheusDataSource = if (cfg.autoConfigure.prometheus && (config.services.prometheus.enable or false)) then {
        "prometheus-auto" = {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://${config.services.prometheus.listenAddress or "127.0.0.1"}:${toString (config.services.prometheus.port or 9090)}";
          isDefault = true;
        };
      } else {};

      # Merge all data sources: user-defined take precedence
      allDataSources = cfg.provisioning.datasources // lokiDataSource // prometheusDataSource;

      # Generate YAML files for Grafana provisioning
      datasourcesConfig = {
        apiVersion = 1;
        datasources = mapAttrsToList (name: ds: ds // {
          uid = "auto-${name}";
          orgId = 1;
        }) allDataSources;
      };

      dashboardsConfig = {
        apiVersion = 1;
        providers = mapAttrsToList (name: dashboard: {
          inherit (dashboard) name folder;
          orgId = 1;
          type = "file";
          disableDeletion = false;
          editable = true;
          updateIntervalSeconds = 60;
          options = {
            path = toString dashboard.path;
          };
        }) cfg.provisioning.dashboards;
      };
    in
    {
      # Note: grafana user and group are automatically created by services.grafana

      # Override Grafana user's home directory to prevent activation script from
      # enforcing 0700 permissions on /var/lib/grafana (which would revert our 0750 tmpfiles rules)
      users.users.grafana.home = lib.mkForce "/var/empty";

      # ZFS dataset configuration
      # Permissions are managed by systemd StateDirectoryMode, not tmpfiles
      modules.storage.datasets.services.grafana = mkIf (cfg.zfs.dataset != null) {
        mountpoint = cfg.dataDir;
        recordsize = "128K"; # Default recordsize for general purpose use
        compression = "zstd"; # Better compression for Grafana database files
        properties = cfg.zfs.properties;
      };

      # Automatically register with Caddy reverse proxy using standardized pattern
      modules.services.caddy.virtualHosts.grafana = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = cfg.reverseProxy.backend;

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # Authelia SSO configuration from shared types
        authelia = cfg.reverseProxy.authelia;

        # Security configuration from shared types with additional headers
        security = cfg.reverseProxy.security // {
          customHeaders = cfg.reverseProxy.security.customHeaders // {
            "X-Frame-Options" = "SAMEORIGIN";
            "X-Content-Type-Options" = "nosniff";
            "X-XSS-Protection" = "1; mode=block";
            "Referrer-Policy" = "strict-origin-when-cross-origin";
          };
        };

        # Additional Caddy configuration
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Register with Authelia if SSO protection is enabled
      modules.services.authelia.accessControl.declarativelyProtectedServices.grafana = mkIf (
        config.modules.services.authelia.enable &&
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
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") (authCfg.bypassPaths or []))
            ++ (authCfg.bypassResources or []);
        }
      );

      # Configure the core Grafana service
      services.grafana = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;

        settings = {
          server = {
            http_addr = cfg.listenAddress;
            http_port = cfg.port;
          } // (lib.optionalAttrs (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
            root_url = "https://${cfg.reverseProxy.hostName}";
          });
          security = {
            admin_user = cfg.secrets.adminUser;
          } // (lib.optionalAttrs (cfg.secrets.adminPasswordFile != null) {
            admin_password = "$__file{${cfg.secrets.adminPasswordFile}}";
          });
          # Disable login form when OIDC is enabled to force SSO
          auth = lib.optionalAttrs cfg.oidc.enable {
            disable_login_form = true;
          };
        } // (lib.optionalAttrs cfg.oidc.enable {
          "auth.generic_oauth" = {
            enabled = true;
            name = "Authelia";
            client_id = cfg.oidc.clientId;
            client_secret = "$__file{${cfg.oidc.clientSecretFile}}";
            scopes = lib.concatStringsSep " " cfg.oidc.scopes;
            auth_url = cfg.oidc.authUrl;
            token_url = cfg.oidc.tokenUrl;
            api_url = cfg.oidc.apiUrl;
            role_attribute_path = cfg.oidc.roleAttributePath;
            allow_sign_up = cfg.oidc.allowSignUp;
          } // (lib.optionalAttrs (cfg.oidc.signoutRedirectUrl != "") {
            signout_redirect_url = cfg.oidc.signoutRedirectUrl;
          });
        });

        provision = {
          enable = true;
          datasources.settings = datasourcesConfig;
          dashboards.settings = dashboardsConfig;
        };
      } // lib.optionalAttrs (cfg.provisioning.plugins != []) {
        # Only enable declarative plugins when list is non-empty. If empty, allow UI-managed plugins.
        declarativePlugins = cfg.provisioning.plugins;
      };

      # Apply systemd hardening and resource limits
      systemd.services.grafana = {
        serviceConfig = {
          # Permissions: Managed by systemd StateDirectory (native approach)
          # StateDirectory tells systemd to create /var/lib/grafana with correct ownership
          # StateDirectoryMode sets directory permissions to 750 (rwxr-x---)
          # UMask 0027 ensures files created by service are 640 (rw-r-----)
          # This allows restic-backup user (member of grafana group) to read data
          StateDirectory = "grafana";
          StateDirectoryMode = "0750";
          UMask = "0027";

          # Resource limits
          MemoryMax = cfg.resources.MemoryMax;
          MemoryReservation = cfg.resources.MemoryReservation;
          CPUQuota = cfg.resources.CPUQuota;

          # Security hardening
          # Align with upstream defaults to avoid blocking writes under /var/lib/grafana
          ProtectSystem = lib.mkForce "full";
          ProtectHome = lib.mkForce "read-only";
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          # Ensure Grafana retains write access to its dataDir even with hardening
          ReadWritePaths = [ cfg.dataDir ];
        };

        # Service dependencies for ZFS dataset mounting and preseed
        after = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ]
          ++ lib.optionals cfg.preseed.enable [ "preseed-grafana.service" ];
        wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ]
          ++ lib.optionals cfg.preseed.enable [ "preseed-grafana.service" ];
      };

      # Validations
      assertions = [
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
          message = "Grafana preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.passwordFile != null);
          message = "Grafana preseed.enable requires preseed.passwordFile to be set.";
        }
      ];
    }
    ))

    # Add the preseed service itself
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "grafana";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "grafana.service";
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
        owner = "grafana";
        group = "grafana";
      }
    ))
  ];
}
