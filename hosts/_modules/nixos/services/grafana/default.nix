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
  inherit (lib) mkOption mkEnableOption mkIf types optionalString mapAttrsToList attrValues;
  cfg = config.modules.services.grafana;
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

    # Consistent submodule for reverse proxy
    reverseProxy = {
      enable = mkEnableOption "Caddy reverse proxy for Grafana";

      subdomain = mkOption {
        type = types.str;
        default = "grafana";
        description = "Subdomain for the reverse proxy";
      };

      auth = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            user = mkOption {
              type = types.str;
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = mkOption {
              type = types.str;
              description = "Environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Authentication configuration";
      };
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

    # Consistent submodule for resource management
    resources = {
      MemoryMax = mkOption {
        type = types.str;
        default = "1G";
        description = "Maximum memory usage";
      };

      MemoryReservation = mkOption {
        type = types.nullOr types.str;
        default = "512M";
        description = "Memory reservation";
      };

      CPUQuota = mkOption {
        type = types.str;
        default = "50%";
        description = "CPU quota";
      };
    };

    # Consistent submodule for backups
    backup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable backup of Grafana configuration and dashboards";
      };

      excludeDataFiles = mkOption {
        type = types.bool;
        default = true;
        description = "Exclude database and runtime data from backups (recommended for ZFS snapshots)";
      };
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

      # Automatically register with Caddy reverse proxy if enabled
      modules.reverseProxy.virtualHosts.${cfg.reverseProxy.subdomain} = mkIf cfg.reverseProxy.enable {
        enable = true;
        hostName = "${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";
        auth = cfg.reverseProxy.auth;
        backend = {
          scheme = "http";
          host = cfg.listenAddress;
          port = cfg.port;
        };

        # Security headers for web interface
        securityHeaders = {
          "X-Frame-Options" = "SAMEORIGIN";
          "X-Content-Type-Options" = "nosniff";
          "X-XSS-Protection" = "1; mode=block";
          "Referrer-Policy" = "strict-origin-when-cross-origin";
        };
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
          } // (lib.optionalAttrs cfg.reverseProxy.enable {
            root_url = "https://${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";
          });
          security = {
            admin_user = cfg.secrets.adminUser;
          } // (lib.optionalAttrs (cfg.secrets.adminPasswordFile != null) {
            admin_password = "$__file{${cfg.secrets.adminPasswordFile}}";
          });
          # Enable proxy authentication if reverse proxy with auth is configured
          "auth.proxy" = mkIf (cfg.reverseProxy.enable && cfg.reverseProxy.auth != null) {
            enabled = true;
            header_name = "Remote-User";
            header_property = "username";
            auto_sign_up = true;
            enable_login_token = false;
          };
        };

        declarativePlugins = cfg.provisioning.plugins;

        provision = {
          enable = true;
          datasources.settings = datasourcesConfig;
          dashboards.settings = dashboardsConfig;
        };
      };

      # Apply systemd hardening and resource limits
      systemd.services.grafana = {
        # Ensure correct ownership of data directory
        preStart = mkIf (cfg.zfs.dataset != null) ''
          chown -R grafana:grafana ${cfg.dataDir}
        '';

        serviceConfig = {
          # Resource limits
          MemoryMax = cfg.resources.MemoryMax;
          MemoryReservation = cfg.resources.MemoryReservation;
          CPUQuota = cfg.resources.CPUQuota;

          # Security hardening
          ProtectSystem = lib.mkForce "strict";
          ProtectHome = lib.mkForce "read-only";
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          SystemCallFilter = [ "@system-service" "~@privileged" ];
        };

        # Service dependencies for ZFS dataset mounting
        after = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
        wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
      };
    }
  );
}
