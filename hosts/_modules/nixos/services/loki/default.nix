{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.modules.services.loki;
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

    reverseProxy = {
      enable = mkEnableOption "reverse proxy for Loki";

      subdomain = mkOption {
        type = types.str;
        default = "loki";
        description = "Subdomain for Loki web interface";
      };

      requireAuth = mkOption {
        type = types.bool;
        default = true;
        description = "Require authentication for web access";
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

    backup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable backup of Loki configuration and rules";
      };

      excludeDataFiles = mkOption {
        type = types.bool;
        default = true;
        description = "Exclude chunks and WAL from backups (recommended for ZFS snapshots)";
      };
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
      mode = "0750";
    };

    # Loki service configuration
    services.loki = {
      enable = true;
      dataDir = cfg.dataDir;

      configuration = lib.recursiveUpdate {
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = cfg.port;
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

    # Automatically register with Caddy reverse proxy if enabled
    modules.reverseProxy.virtualHosts.${cfg.reverseProxy.subdomain} = mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";
      backend = {
        scheme = "http";
        host = "localhost";
        port = cfg.port;
      };
      auth = mkIf (cfg.reverseProxy.requireAuth && cfg.reverseProxy.auth != null) cfg.reverseProxy.auth;

      # Headers that go inside the reverse_proxy block
      vendorExtensions.caddy.reverseProxyBlock = ''
        # Loki API headers for proper log ingestion
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
      '';

      # Security headers that go at the site level
      securityHeaders = {
        "X-Frame-Options" = "DENY";
        "X-Content-Type-Options" = "nosniff";
        "X-XSS-Protection" = "1; mode=block";
        "Referrer-Policy" = "strict-origin-when-cross-origin";
      };
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
