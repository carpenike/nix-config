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
        excludePatterns = [
          "**/*.db"          # Exclude SQLite database (use ZFS snapshots instead)
          "**/sessions/*"    # Exclude session data
          "**/png/*"         # Exclude rendered images
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

  config = mkIf cfg.enable (
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

      # ZFS dataset configuration
      modules.storage.datasets.services.grafana = mkIf (cfg.zfs.dataset != null) {
        mountpoint = cfg.dataDir;
        recordsize = "128K"; # Default recordsize for general purpose use
        compression = "zstd"; # Better compression for Grafana database files
        properties = cfg.zfs.properties;
        owner = "grafana";
        group = "grafana";
        mode = "0750";
      };

      # Automatically register with Caddy reverse proxy using standardized pattern
      modules.services.caddy.virtualHosts.grafana = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = cfg.reverseProxy.backend;

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

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
        };

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
        # NOTE: Do not add a chown here; systemd seccomp blocks chown in ExecStartPre.
        # Ownership is ensured by modules.storage.datasets tmpfiles rules.

        serviceConfig = {
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

        # Service dependencies for ZFS dataset mounting
        after = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ];
        wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" "zfs-service-datasets.service" ];
      };
    }
  );
}
