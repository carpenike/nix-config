{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mapAttrsToList filter concatLists;
  cfg = config.modules.services.observability;

  # Auto-discovery function for services with metrics submodules
  # Uses the same safe pattern as backup-integration.nix to avoid nix store path issues
  discoverMetricsTargets = config:
    let
      # Extract all modules.services.* configurations (excluding observability to prevent recursion)
      allServices = lib.filterAttrs (name: service: name != "observability") (config.modules.services or {});

      # Filter services that have metrics enabled
      servicesWithMetrics = lib.filterAttrs (name: service:
        (service.metrics or null) != null &&
        (service.metrics.enable or false)
      ) allServices;

      # Convert to Prometheus scrape_config format
      scrapeConfigs = mapAttrsToList (serviceName: service: {
        job_name = "service-${serviceName}";
        static_configs = [{
          targets = [ "${service.metrics.interface or "127.0.0.1"}:${toString service.metrics.port}" ];
          labels = (service.metrics.labels or {}) // {
            service = serviceName;
            instance = config.networking.hostName;
          };
        }];
        metrics_path = service.metrics.path or "/metrics";
        scrape_interval = service.metrics.scrapeInterval or "60s";
        scrape_timeout = service.metrics.scrapeTimeout or "10s";
        relabel_configs = service.metrics.relabelConfigs or [];
      }) servicesWithMetrics;
    in
      scrapeConfigs;

  # Generate discovered scrape configurations (safe from recursion)
  discoveredScrapeConfigs =
    if cfg.prometheus.autoDiscovery.enable
    then discoverMetricsTargets config
    else [];
in
{
  options.modules.services.observability = {
    enable = mkEnableOption "observability stack (Loki + Promtail + Grafana + Prometheus)";

    prometheus = {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        description = "Enable Prometheus metrics collection server";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/prometheus";
        description = "Directory to store Prometheus data";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/prometheus";
        description = "ZFS dataset for Prometheus data storage";
      };

      retentionDays = mkOption {
        type = types.int;
        default = 30;
        description = "Metrics retention period in days";
      };

      port = mkOption {
        type = types.port;
        default = 9090;
        description = "Port for Prometheus web interface";
      };

      autoDiscovery = {
        enable = mkOption {
          type = types.bool;
          default = true; # Re-enabled with safe discovery pattern
          description = "Enable automatic discovery of service metrics endpoints";
        };

        staticTargets = mkOption {
          type = types.listOf types.attrs;
          default = [];
          description = "Additional static scrape targets";
          example = [{
            job_name = "node-exporter";
            static_configs = [{
              targets = [ "localhost:9100" ];
            }];
          }];
        };
      };
    };

    loki = {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        description = "Enable Loki log aggregation server";
      };

      retentionDays = mkOption {
        type = types.int;
        default = 14;
        description = "Log retention period in days";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/loki";
        description = "Directory to store Loki data";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/loki";
        description = "ZFS dataset for Loki data storage";
      };
    };

    promtail = {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        description = "Enable Promtail log shipping agent";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/promtail";
        description = "Directory to store Promtail data (positions.yaml and state)";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/promtail";
        description = "ZFS dataset for Promtail data storage";
      };

      containerLogSource = mkOption {
        type = types.enum [ "journald" "podmanFiles" ];
        default = "journald";
        description = "Source for container logs";
      };

      dropNoisyUnits = mkOption {
        type = types.listOf types.str;
        default = [
          "systemd-logind"
          "systemd-networkd"
          "systemd-resolved"
          "systemd-timesyncd"
          "NetworkManager"
        ];
        description = "Systemd units to exclude from log collection";
      };
    };

    grafana = {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        description = "Enable Grafana monitoring dashboard";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/grafana";
        description = "Directory to store Grafana data";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/grafana";
        description = "ZFS dataset for Grafana data storage";
      };

      subdomain = mkOption {
        type = types.str;
        default = "grafana";
        description = "Subdomain for Grafana web interface";
      };

      adminUser = mkOption {
        type = types.str;
        default = "admin";
        description = "Grafana admin user name";
      };

      adminPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing Grafana admin password (SOPS managed)";
      };

      plugins = mkOption {
        type = with types; listOf package;
        default = [];
        example = lib.literalExpression "with pkgs.grafanaPlugins; [ grafana-worldmap-panel ]";
        description = "List of Grafana plugins to install";
      };

      autoConfigure = {
        loki = mkOption {
          type = types.bool;
          default = cfg.loki.enable;
          description = "Automatically configure Loki data source";
        };

        prometheus = mkOption {
          type = types.bool;
          default = true;
          description = "Automatically configure Prometheus data source if available";
        };
      };
    };

    reverseProxy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable reverse proxy access to Loki";
      };

      subdomain = mkOption {
        type = types.str;
        default = "loki";
        description = "Subdomain for Loki web interface";
      };

      auth = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            user = mkOption {
              type = types.str;
              default = "admin";
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = mkOption {
              type = types.str;
              description = "Environment variable containing bcrypt password hash";
            };
          };
        });
        default = {
          user = "admin";
          passwordHashEnvVar = null;
        };
        description = "Authentication configuration for Loki web interface";
      };
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable backup of Loki rules and configuration";
      };

      includeChunks = mkOption {
        type = types.bool;
        default = false;
        description = "Include log chunks in backup (not recommended with ZFS snapshots)";
      };
    };

    alerts = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Loki alerting rules";
      };

      rules = mkOption {
        type = types.listOf types.attrs;
        default = [
          {
            alert = "LokiNoLogsIngested";
            expr = "rate(loki_distributor_bytes_received_total[5m]) == 0";
            for = "10m";
            labels = {
              severity = "warning";
              service = "loki";
            };
            annotations = {
              summary = "Loki is not ingesting logs";
              description = "No logs have been ingested by Loki in the last 10 minutes";
            };
          }
          {
            alert = "LokiQueryErrors";
            expr = "increase(loki_querier_queries_failed_total[5m]) > 0";
            for = "5m";
            labels = {
              severity = "warning";
              service = "loki";
            };
            annotations = {
              summary = "Loki query failures detected";
              description = "{{ $value }} query failures in the last 5 minutes";
            };
          }
          {
            alert = "PromtailDroppingLogs";
            expr = "increase(promtail_client_dropped_bytes_total[5m]) > 0";
            for = "5m";
            labels = {
              severity = "critical";
              service = "promtail";
            };
            annotations = {
              summary = "Promtail is dropping logs";
              description = "Promtail has dropped {{ $value }} bytes of logs in the last 5 minutes";
            };
          }
        ];
        description = "Alerting rules for Loki and Promtail";
      };
    };
  };

  config = mkIf cfg.enable {
    # Enhance existing Prometheus configuration with auto-discovery
    # This adds auto-discovered targets to any existing scrapeConfigs
    services.prometheus = mkIf cfg.prometheus.enable {
      enable = true;
      port = cfg.prometheus.port;
      stateDir = "prometheus";
      retentionTime = "${toString cfg.prometheus.retentionDays}d";

      # Merge auto-discovered targets with static configurations
      scrapeConfigs = discoveredScrapeConfigs ++ cfg.prometheus.autoDiscovery.staticTargets;

      # Global configuration (only set if not already configured)
      globalConfig = lib.mkDefault {
        scrape_interval = "15s";
        evaluation_interval = "15s";
        external_labels = {
          instance = config.networking.hostName;
          environment = "homelab";
        };
      };

      # Enable web interface with basic configuration
      webExternalUrl = lib.mkDefault "http://localhost:${toString cfg.prometheus.port}";
      listenAddress = lib.mkDefault "127.0.0.1";

      # Resource limits for homelab
      extraFlags = lib.mkDefault [
        "--storage.tsdb.retention.time=${toString cfg.prometheus.retentionDays}d"
        "--web.console.libraries=/etc/prometheus/console_libraries"
        "--web.console.templates=/etc/prometheus/consoles"
        "--web.enable-lifecycle"
        "--log.level=info"
      ];
    };

    # Configure ZFS dataset for Prometheus if specified
    modules.storage.datasets.services.prometheus = mkIf (cfg.prometheus.enable && cfg.prometheus.zfsDataset != null) {
      mountpoint = "/var/lib/prometheus2"; # Default NixOS Prometheus data directory
      recordsize = "16K"; # Optimized for time series data
      compression = "lz4"; # Fast compression for metrics
      properties = {
        "com.sun:auto-snapshot" = "true";
        atime = "off"; # Reduce write load
      };
      owner = "prometheus";
      group = "prometheus";
      mode = "0755";
    };

    # Auto-configure Prometheus reverse proxy
    modules.services.caddy.virtualHosts.prometheus = mkIf (cfg.prometheus.enable && cfg.reverseProxy.enable) {
      enable = true;
      hostName = "prometheus.${config.networking.domain or "holthome.net"}";
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.prometheus.port;
      };
      auth = cfg.reverseProxy.auth;
      security.customHeaders = {
        "X-Frame-Options" = "SAMEORIGIN";
        "X-Content-Type-Options" = "nosniff";
      };
    };

    # Enable Loki service
    modules.services.loki = mkIf cfg.loki.enable {
      enable = true;
      dataDir = cfg.loki.dataDir;
      retentionDays = cfg.loki.retentionDays;

      # ZFS configuration
      zfs = mkIf (cfg.loki.zfsDataset != null) {
        dataset = cfg.loki.zfsDataset;
        properties = {
          compression = "zstd";
          recordsize = "1M"; # Optimized for log chunks
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
      };

      # Reverse proxy configuration
      reverseProxy = mkIf cfg.reverseProxy.enable {
        enable = true;
        subdomain = cfg.reverseProxy.subdomain;
        requireAuth = cfg.reverseProxy.auth != null;
        auth = cfg.reverseProxy.auth;
      };

      # Backup configuration
      backup = {
        enable = false; # Handled by ZFS snapshots
        excludeDataFiles = !cfg.backup.includeChunks;
      };

      # Resource limits for homelab
      resources = {
        MemoryMax = "512M";
        MemoryReservation = "256M";
        CPUQuota = "50%";
      };
    };

    # Enable Promtail service
    modules.services.promtail = mkIf cfg.promtail.enable {
      enable = true;
      dataDir = cfg.promtail.dataDir;

      # ZFS configuration
      zfs = mkIf (cfg.promtail.zfsDataset != null) {
        dataset = cfg.promtail.zfsDataset;
        properties = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
      };

      # Container log source configuration
      containers = {
        enable = true;
        source = cfg.promtail.containerLogSource;
      };

      # Journal configuration with noise reduction
      journal = {
        enable = true;
        maxAge = "12h";
        dropIdentifiers = cfg.promtail.dropNoisyUnits;
        labels = {
          job = "systemd-journal";
          host = config.networking.hostName;
          environment = "homelab";
        };
      };

      # Resource limits for homelab
      resources = {
        MemoryMax = "128M";
        CPUQuota = "25%";
      };

      # Connect to local Loki instance
      lokiUrl = "http://127.0.0.1:${toString config.modules.services.loki.port}";
    };

    # Enable Grafana service
    modules.services.grafana = mkIf cfg.grafana.enable {
      enable = true;
      dataDir = cfg.grafana.dataDir;

      # ZFS configuration
      zfs = mkIf (cfg.grafana.zfsDataset != null) {
        dataset = cfg.grafana.zfsDataset;
        properties = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
      };

      # Auto-configure data sources
      autoConfigure = {
        loki = cfg.grafana.autoConfigure.loki;
        prometheus = cfg.grafana.autoConfigure.prometheus;
      };

      # Reverse proxy configuration
      reverseProxy = {
        enable = cfg.reverseProxy.enable;
        subdomain = cfg.grafana.subdomain;
        auth = cfg.reverseProxy.auth;
      };

      # Secrets configuration
      secrets = {
        adminUser = cfg.grafana.adminUser;
      } // lib.optionalAttrs (cfg.grafana.adminPasswordFile != null) {
        adminPasswordFile = cfg.grafana.adminPasswordFile;
      };

      # Plugin configuration
      provisioning.plugins = cfg.grafana.plugins;

      # Resource limits for homelab
      resources = {
        MemoryMax = "1G";
        MemoryReservation = "512M";
        CPUQuota = "50%";
      };

      # Backup configuration
      backup = {
        enable = cfg.backup.enable;
        excludeDataFiles = true; # Rely on ZFS snapshots for data
      };
    };

    # Service integration and metrics endpoints:
    # - Loki API: http://127.0.0.1:${toString config.modules.services.loki.port}
    # - Loki metrics: http://127.0.0.1:${toString config.modules.services.loki.port}/metrics
    # - Promtail metrics: http://127.0.0.1:${toString config.modules.services.promtail.port}/metrics
    # - Grafana UI: http://127.0.0.1:${toString config.modules.services.grafana.port} (or via reverse proxy)
    # - Data sources are automatically configured in Grafana when autoConfigure is enabled

    # System packages for log analysis (optional)
    environment.systemPackages =
      (lib.optional cfg.loki.enable pkgs.grafana-loki) ++
      (lib.optional cfg.grafana.enable pkgs.grafana);

    # Note: Log directories created automatically by NixOS services
  };
}
