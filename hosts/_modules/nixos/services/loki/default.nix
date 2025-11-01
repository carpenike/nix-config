{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.modules.services.loki;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.loki = {
    enable = mkEnableOption "Grafana Loki log aggregation server";

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/loki";
      description = "Directory to store Loki data";
    };

    port = mkOption {
      type = types.port;
      default = 3100;
      description = "Port for Loki HTTP server";
    };

    grpcPort = mkOption {
      type = types.port;
      default = 9095; # Upstream default; required for querier<->ingester and tailing
      description = "Port for Loki gRPC server (set to a non-conflicting port; 0 disables gRPC)";
    };

    retentionDays = mkOption {
      type = types.int;
      default = 14;
      description = "Log retention period in days";
    };

    resources = mkOption {
      type = types.attrsOf types.str;
      default = {
        MemoryMax = "512M";
        MemoryReservation = "256M";
        CPUQuota = "50%";
      };
      description = "Resource limits for the Loki systemd service";
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Loki web interface";
    };

    # Standardized metrics collection pattern
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 3100;
        path = "/metrics";
        labels = {
          service_type = "log_aggregation";
          exporter = "loki";
          function = "storage";
        };
      };
      description = "Prometheus metrics collection configuration for Loki";
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "loki.service";
        labels = {
          service = "loki";
          service_type = "log_aggregation";
        };
      };
      description = "Log shipping configuration for Loki logs";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "logs" "loki" "config" ];
        # CRITICAL: Enable ZFS snapshots for database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/loki";
        excludePatterns = lib.mkDefault [
          "**/boltdb-shipper-cache/**"  # Exclude cache directories
          "**/compactor/boltdb-shipper-compactor/**"  # Exclude compactor temp files
          "**/*.tmp"                    # Exclude temporary files
        ];
      };
      description = "Backup configuration for Loki";
    };

    # Standardized notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "critical-logs" ];
        };
        customMessages = {
          failure = "Loki log aggregation server failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Loki service events";
    };

    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/loki";
        description = "ZFS dataset to mount at dataDir";
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = {
          compression = "zstd";
          recordsize = "1M";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        description = "ZFS dataset properties";
      };
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level for Loki";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Additional Loki configuration";
    };

    # Cardinality and safety limits
    limits = mkOption {
      type = types.attrs;
      default = {
        # Prevent bad agents from ingesting very old data
        reject_old_samples = true;
        reject_old_samples_max_age = "168h"; # 7 days

        # Control cardinality; adjust as needed
        max_active_streams_per_user = 5000;
        max_label_names_per_user = 100;

        # Ingestion rate limiting per distributor
        ingestion_rate_mb = 4;
        ingestion_burst_size_mb = 6;

        # Additional safety limits
        per_stream_rate_limit = "3MB";
        max_entries_limit_per_query = 5000;
      };
      description = "Loki limits_config values to control cardinality and ingestion rates";
    };
  };

  config = mkIf cfg.enable {
    # Note: Using NixOS built-in loki user/group from services.loki

    # ZFS dataset configuration
    modules.storage.datasets.services.loki = mkIf (cfg.zfs.dataset != null) {
      mountpoint = cfg.dataDir;
      recordsize = "1M";  # Optimized for log chunks (large sequential writes)
      compression = "zstd";  # Better compression for text logs
      properties = cfg.zfs.properties;
      owner = "loki";
      group = "loki";
      mode = "0750";  # Allow group read access for backup systems
    };

    # Loki service configuration
    services.loki = {
      enable = true;
      dataDir = cfg.dataDir;

      configuration = lib.recursiveUpdate {
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = cfg.port;
          grpc_listen_port = cfg.grpcPort;
          log_level = cfg.logLevel;
        };

        auth_enabled = false;

        ingester = {
          lifecycler = {
            address = "127.0.0.1";
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
          };
          chunk_idle_period = "3m";
          chunk_block_size = 262144;
          chunk_retain_period = "1m";
        };

        schema_config = {
          configs = [
            {
              from = "2020-10-24";
              store = "boltdb-shipper";
              object_store = "filesystem";
              schema = "v11";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };

        storage_config = {
          boltdb_shipper = {
            active_index_directory = "${cfg.dataDir}/boltdb-shipper-active";
            cache_location = "${cfg.dataDir}/boltdb-shipper-cache";
          };
          filesystem = {
            directory = "${cfg.dataDir}/chunks";
          };
        };

        limits_config = {
          retention_period = "${toString cfg.retentionDays}d";
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
          ingestion_rate_mb = 4;
          ingestion_burst_size_mb = 6;
          allow_structured_metadata = false;  # Required for schema v11
        };

        compactor = {
          working_directory = "${cfg.dataDir}/compactor";
          compaction_interval = "10m";
          retention_enabled = true;
          retention_delete_delay = "2h";
          retention_delete_worker_count = 150;
          delete_request_store = "filesystem";  # Required for retention
        };

        query_range = {
          results_cache = {
            cache = {
              embedded_cache = {
                enabled = true;
                max_size_mb = 100;
              };
            };
          };
        };

        frontend = {
          log_queries_longer_than = "5s";
          compress_responses = true;
        };

        ruler = {
          storage = {
            type = "local";
            local = {
              directory = "${cfg.dataDir}/rules";
            };
          };
          rule_path = "${cfg.dataDir}/rules-temp";
          ring = {
            kvstore = {
              store = "inmemory";
            };
          };
          enable_api = true;
        };
      } cfg.extraConfig;
    };

    # Systemd service resource limits and ZFS dependencies
    systemd.services.loki = {
      serviceConfig = {
        # Resource limits for homelab deployment
        MemoryMax = cfg.resources.MemoryMax;
        MemoryReservation = cfg.resources.MemoryReservation or null;
        CPUQuota = cfg.resources.CPUQuota;
      };

      # Service dependencies for ZFS dataset mounting
      after = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
      wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
    };

    # Automatically register with Caddy reverse proxy using standardized pattern
    modules.services.caddy.virtualHosts.loki = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = cfg.reverseProxy.backend;

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Security configuration from shared types with additional headers
      security = cfg.reverseProxy.security // {
        customHeaders = cfg.reverseProxy.security.customHeaders // {
          "X-Frame-Options" = "DENY";
          "X-Content-Type-Options" = "nosniff";
          "X-XSS-Protection" = "1; mode=block";
          "Referrer-Policy" = "strict-origin-when-cross-origin";
        };
      };

      # Additional Caddy configuration
      extraConfig = cfg.reverseProxy.extraConfig;

      # Loki-specific reverse proxy directives
      reverseProxyBlock = ''
        # Loki API headers for proper log ingestion
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
      '';
    };

    # Backup configuration
    # Note: Backup can be configured at the host level using the backup.restic system
    # Loki relies on ZFS snapshots for primary data protection

    # Firewall configuration (only allow local access)
    networking.firewall = {
      interfaces.lo.allowedTCPPorts = [ cfg.port ];
    };

    # Ensure correct ownership of data directory and subdirectories
    # This is required because ZFS datasets are mounted as root:root
    # but the service runs as the loki user
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 loki loki -"
      "d ${cfg.dataDir}/chunks 0755 loki loki -"
      "d ${cfg.dataDir}/rules 0755 loki loki -"
      "d ${cfg.dataDir}/boltdb-shipper-active 0755 loki loki -"
      "d ${cfg.dataDir}/boltdb-shipper-cache 0755 loki loki -"
      "d ${cfg.dataDir}/compactor 0755 loki loki -"
      "d ${cfg.dataDir}/rules-temp 0755 loki loki -"
    ];

    # Monitoring integration - expose metrics
    # Note: Metrics available at http://127.0.0.1:${port}/metrics for manual Prometheus scraping
  };
}
