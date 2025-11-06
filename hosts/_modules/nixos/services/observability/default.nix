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

      backup = {
        enable = mkOption {
          type = types.bool;
          default = cfg.loki.enable;
          defaultText = lib.literalExpression "config.modules.services.observability.loki.enable";
          description = "Enable backup of Loki data and configuration";
        };

        includeChunks = mkOption {
          type = types.bool;
          default = false;
          description = "Include log chunks in backup (not recommended with ZFS snapshots)";
        };
      };

      preseed = {
        enable = mkEnableOption "automatic data restore before Loki service start";

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

      extraScrapeConfigs = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = "Additional Promtail scrape configurations for custom log sources";
      };

      syslog = mkOption {
        type = types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Enable Promtail syslog receiver";
            };
            address = mkOption {
              type = types.str;
              default = "0.0.0.0";
              description = "Listen address for syslog receiver";
            };
            port = mkOption {
              type = types.port;
              default = 1514;
              description = "Listen port for syslog receiver";
            };
            protocol = mkOption {
              type = types.enum [ "udp" "tcp" ];
              default = "udp";
              description = "Syslog transport protocol";
            };
            labelStructuredData = mkOption {
              type = types.bool;
              default = false;
              description = "Expose RFC5424 structured data (SD) fields as labels";
            };
            idleTimeout = mkOption {
              type = types.str;
              default = "60s";
              description = "Idle timeout for syslog connections";
            };
            useIncomingTimestamp = mkOption {
              type = types.bool;
              default = true;
              description = "Use the timestamp from incoming syslog messages when present";
            };
          };
        };
        default = { };
        description = "Promtail syslog receiver configuration";
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

      backup = {
        enable = mkOption {
          type = types.bool;
          default = cfg.grafana.enable;
          defaultText = lib.literalExpression "config.modules.services.observability.grafana.enable";
          description = "Enable backup of Grafana dashboards and configuration";
        };
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

      preseed = {
        enable = mkEnableOption "automatic data restore before Grafana service start";

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
    # Permissions are managed by systemd StateDirectoryMode, not tmpfiles
    modules.storage.datasets.services.prometheus = mkIf (cfg.prometheus.enable && cfg.prometheus.zfsDataset != null) {
      mountpoint = "/var/lib/prometheus2"; # Default NixOS Prometheus data directory
      recordsize = "16K"; # Optimized for time series data
      compression = "lz4"; # Fast compression for metrics
      properties = {
        "com.sun:auto-snapshot" = "true";
        atime = "off"; # Reduce write load
      };
    };

    # Set permissions for Prometheus using systemd StateDirectoryMode
    systemd.services.prometheus.serviceConfig = mkIf cfg.prometheus.enable {
      # Override upstream default of 0700 to allow group read access
      # StateDirectoryMode sets directory permissions to 750 (rwxr-x---)
      # UMask 0027 ensures files created by service are 640 (rw-r-----)
      # This allows restic-backup user (member of prometheus group) to read data
      StateDirectoryMode = lib.mkForce "0750";
      UMask = "0027";
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
      authelia = cfg.reverseProxy.authelia;
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
      reverseProxy = lib.mkIf cfg.reverseProxy.enable {
        enable = true;
        hostName = "${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = 3100;
        };
        auth = cfg.reverseProxy.auth;
      };

      # Backup configuration
      backup = lib.mkIf cfg.loki.backup.enable {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "logs" "loki" "config" ];
        # Enable ZFS snapshots for consistent backups (Gemini Pro recommendation)
        useSnapshots = cfg.loki.zfsDataset != null;
        zfsDataset = cfg.loki.zfsDataset;
        excludePatterns = if cfg.loki.backup.includeChunks then [] else [
          "**/chunks/**"
          "**/wal/**"
          "**/boltdb-shipper-cache/**"
        ];
      };

      # Resource limits for homelab
      resources = {
        MemoryMax = "512M";
        MemoryReservation = "256M";
        CPUQuota = "50%";
      };

      # Preseed configuration for disaster recovery
      preseed = lib.mkIf cfg.loki.preseed.enable {
        enable = true;
        repositoryUrl = cfg.loki.preseed.repositoryUrl;
        passwordFile = cfg.loki.preseed.passwordFile;
        environmentFile = cfg.loki.preseed.environmentFile;
        restoreMethods = cfg.loki.preseed.restoreMethods;
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

      # Syslog receiver passthrough
      syslog = {
        enable = cfg.promtail.syslog.enable;
        address = cfg.promtail.syslog.address;
        port = cfg.promtail.syslog.port;
        protocol = cfg.promtail.syslog.protocol;
        labelStructuredData = cfg.promtail.syslog.labelStructuredData or false;
        idleTimeout = cfg.promtail.syslog.idleTimeout or "60s";
        useIncomingTimestamp = cfg.promtail.syslog.useIncomingTimestamp or true;
      };
      extraScrapeConfigs = cfg.promtail.extraScrapeConfigs ++ [
        {
          job_name = "omada-file";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "omada-file";
                app = "omada";
                __path__ = "/var/log/omada-raw.log";
              };
            }
          ];
          pipeline_stages = [
            { labels = { env = "homelab"; }; }
          ];
        }
      ];
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
      reverseProxy = lib.mkIf cfg.reverseProxy.enable {
        enable = true;
        hostName = "${cfg.grafana.subdomain}.${config.networking.domain or "holthome.net"}";
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = 3000;
        };
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
      backup = lib.mkIf cfg.grafana.backup.enable {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "monitoring" "grafana" "dashboards" ];
        # CRITICAL: Enable ZFS snapshots for SQLite database consistency (Gemini Pro recommendation)
        # Backing up live SQLite databases can result in corrupt backups. ZFS snapshots
        # provide a crash-consistent point-in-time copy of the entire database.
        useSnapshots = cfg.grafana.zfsDataset != null;
        zfsDataset = cfg.grafana.zfsDataset;
        excludePatterns = [
          "**/sessions/*"    # Exclude session data
          "**/png/*"         # Exclude rendered images
          "**/csv/*"         # Exclude CSV exports
          "**/pdf/*"         # Exclude PDF exports
        ];
      };

      # Preseed configuration for disaster recovery
      preseed = lib.mkIf cfg.grafana.preseed.enable {
        enable = true;
        repositoryUrl = cfg.grafana.preseed.repositoryUrl;
        passwordFile = cfg.grafana.preseed.passwordFile;
        environmentFile = cfg.grafana.preseed.environmentFile;
        restoreMethods = cfg.grafana.preseed.restoreMethods;
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
