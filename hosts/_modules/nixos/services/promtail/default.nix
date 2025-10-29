{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.modules.services.promtail;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.promtail = {
    enable = mkEnableOption "Promtail log shipping agent";

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/promtail";
      description = "Directory to store Promtail data (positions.yaml and state)";
    };

    port = mkOption {
      type = types.port;
      default = 9080;
      description = "Port for Promtail HTTP server (metrics)";
    };

    grpcPort = mkOption {
      type = types.int;
      default = 0; # disable gRPC by default to avoid conflict with Loki (9095)
      description = "Port for Promtail gRPC server (0 disables)";
    };

    lokiUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3100";
      description = "URL of the Loki server to send logs to";
    };

    resources = mkOption {
      type = types.attrsOf types.str;
      default = {
        MemoryMax = "128M";
        CPUQuota = "25%";
      };
      description = "Resource limits for the Promtail systemd service";
    };

    journal = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable systemd journal log collection";
      };

      maxAge = mkOption {
        type = types.str;
        default = "12h";
        description = "Maximum age of journal entries to process on startup";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {
          job = "systemd-journal";
          host = config.networking.hostName;
        };
        description = "Static labels to add to journal logs";
      };

      dropIdentifiers = mkOption {
        type = types.listOf types.str;
        default = [
          "systemd-logind"
          "systemd-networkd"
          "systemd-resolved"
          "systemd-timesyncd"
        ];
        description = "Systemd unit identifiers to drop (reduce noise)";
      };
    };

    containers = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable container log collection";
      };

      source = mkOption {
        type = types.enum [ "journald" "podmanFiles" ];
        default = "journald";
        description = "Source for container logs: journald (systemd-managed) or podmanFiles (direct file logs)";
      };

      podmanLogsPath = mkOption {
        type = types.str;
        default = "/var/lib/containers/storage/overlay-containers/*/userdata/ctr.log";
        description = "Glob pattern for Podman container log files";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {
          job = "containers";
          host = config.networking.hostName;
        };
        description = "Static labels to add to container logs";
      };
    };

    extraScrapeConfigs = mkOption {
      type = types.listOf types.attrs;
      default = [];
      description = "Additional scrape configurations";
      example = [
        {
          job_name = "nginx";
          static_configs = [{
            targets = ["localhost"];
            labels = {
              job = "nginx";
              __path__ = "/var/log/nginx/*.log";
            };
          }];
        }
      ];
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level for Promtail";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = "Additional Promtail configuration";
    };

    # Syslog receiver (accept logs from external systems)
    syslog = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable built-in syslog receiver (RFC5424/3164)";
      };

      address = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Listen address for syslog receiver";
      };

      port = mkOption {
        type = types.port;
        default = 1514; # unprivileged alt to 514
        description = "Listen port for syslog receiver (use 1514 unless binding to 514 is required)";
      };

      protocol = mkOption {
        type = types.enum [ "udp" "tcp" ];
        default = "udp";
        description = "Syslog transport protocol";
      };

      idleTimeout = mkOption {
        type = types.str;
        default = "60s";
        description = "Idle timeout for syslog connections";
      };

      labelStructuredData = mkOption {
        type = types.bool;
        default = false;
        description = "Expose structured data as labels";
      };

      useIncomingTimestamp = mkOption {
        type = types.bool;
        default = true;
        description = "Use incoming syslog message timestamp when available";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {
          job = "syslog";
          host = config.networking.hostName;
        };
        description = "Static labels to add to syslog streams";
      };
    };

    # Standardized metrics collection pattern
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 9080;
        path = "/metrics";
        labels = {
          service_type = "log_agent";
          exporter = "promtail";
          function = "shipping";
        };
      };
      description = "Prometheus metrics collection configuration for Promtail";
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Promtail metrics endpoint";
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "promtail.service";
        labels = {
          service = "promtail";
          service_type = "log_agent";
        };
      };
      description = "Log shipping configuration for Promtail logs";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "logs" "promtail" "config" ];
        excludePatterns = [
          "**/positions.yaml"   # Exclude position tracking file
          "**/*.tmp"            # Exclude temporary files
        ];
      };
      description = "Backup configuration for Promtail";
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
          failure = "Promtail log shipping agent failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Promtail service events";
    };

    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/promtail";
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
  };

  config = mkIf cfg.enable {
    # Note: Using NixOS built-in promtail user/group from services.promtail
    # Adding systemd-journal group access for log reading
    users.users.promtail.extraGroups = [ "systemd-journal" ];

    # ZFS dataset configuration
    modules.storage.datasets.services.promtail = mkIf (cfg.zfs.dataset != null) {
      mountpoint = cfg.dataDir;
      properties = cfg.zfs.properties;
      owner = "promtail";
      group = "promtail";
      mode = "0750";  # Allow group read access for backup systems
    };

    # Promtail service configuration
    services.promtail = {
      enable = true;

      configuration = lib.recursiveUpdate {
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = cfg.port;
          grpc_listen_port = cfg.grpcPort;
          log_level = cfg.logLevel;
        };

        positions = {
          filename = "${cfg.dataDir}/positions.yaml";
        };

        clients = [
          {
            url = "${cfg.lokiUrl}/loki/api/v1/push";
            backoff_config = {
              min_period = "500ms";
              max_period = "5m";
              max_retries = 20;
            };
            batchsize = 1048576; # 1MB
            batchwait = "1s";
            timeout = "10s";
          }
        ];

        scrape_configs =
          # Systemd journal scraping
          (lib.optional cfg.journal.enable {
            job_name = "journal";
            journal = {
              max_age = cfg.journal.maxAge;
              labels = cfg.journal.labels;
              path = "/var/log/journal";
            };
            relabel_configs = [
              # Map systemd fields to labels
              {
                source_labels = [ "__journal__systemd_unit" ];
                target_label = "unit";
              }
              # Normalize unit → app for cross-source consistency (strip .service)
              {
                source_labels = [ "__journal__systemd_unit" ];
                regex = "([^.]+)\\.service";
                target_label = "app";
                replacement = "$1";
              }
              {
                source_labels = [ "__journal__hostname" ];
                target_label = "host";
              }
              {
                source_labels = [ "__journal_priority_keyword" ];
                target_label = "level";
              }
              {
                source_labels = [ "__journal__systemd_user_unit" ];
                target_label = "user_unit";
              }
              # Drop noisy systemd units
            ] ++ (map (identifier: {
              source_labels = [ "__journal__systemd_unit" ];
              regex = "${identifier}\\.service";
              action = "drop";
            }) cfg.journal.dropIdentifiers);
            pipeline_stages = [
              # Promote stable, low-cardinality labels for taxonomy
              {
                labels = {
                  env = "homelab";
                };
              }
            ];
          }) ++

          # Container logs (journald source)
          (lib.optional (cfg.containers.enable && cfg.containers.source == "journald") {
            job_name = "containers-journal";
            journal = {
              max_age = cfg.journal.maxAge;
              labels = cfg.containers.labels;
              path = "/var/log/journal";
            };
            relabel_configs = [
              # Only keep container logs
              {
                source_labels = [ "__journal__systemd_unit" ];
                regex = "podman-.*\\.service";
                action = "keep";
              }
              # Extract container name from unit
              {
                source_labels = [ "__journal__systemd_unit" ];
                regex = "podman-(.+)\\.service";
                target_label = "container";
              }
              {
                source_labels = [ "__journal__hostname" ];
                target_label = "host";
              }
              {
                source_labels = [ "__journal_priority_keyword" ];
                target_label = "level";
              }
            ];
            pipeline_stages = [
              # Normalize taxonomy
              {
                labels = {
                  env = "homelab";
                };
              }
              # Parse container logs
              {
                regex = {
                  expression = "^(?P<timestamp>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d+Z)\\s+(?P<stream>stdout|stderr)\\s+[FP]\\s+(?P<message>.*)$";
                };
              }
              {
                labels = {
                  stream = null;
                };
              }
              {
                timestamp = {
                  source = "timestamp";
                  format = "RFC3339Nano";
                };
              }
              # Drop ultra-noisy health checks (example)
              {
                match = {
                  selector = "{job=\"containers-journal\"} |= \"/health\"";
                  action = "drop";
                };
              }
            ];
          }) ++

          # Container logs (file source)
          (lib.optional (cfg.containers.enable && cfg.containers.source == "podmanFiles") {
            job_name = "containers-files";
            static_configs = [{
              targets = [ "localhost" ];
              labels = cfg.containers.labels // {
                __path__ = cfg.containers.podmanLogsPath;
              };
            }];
            relabel_configs = [
              # Extract container name from path
              {
                source_labels = [ "__path__" ];
                regex = ".*/overlay-containers/([^/]+)/userdata/ctr\\.log";
                target_label = "container_id";
              }
            ];
            pipeline_stages = [
              { labels = { env = "homelab"; }; }
              # Parse container log format
              {
                regex = {
                  expression = "^(?P<timestamp>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d+Z)\\s+(?P<stream>stdout|stderr)\\s+[FP]\\s+(?P<message>.*)$";
                };
              }
              {
                labels = {
                  stream = null;
                };
              }
              {
                timestamp = {
                  source = "timestamp";
                  format = "RFC3339Nano";
                };
              }
            ];
          }) ++

          # Syslog receiver (external systems)
          (lib.optional cfg.syslog.enable {
            job_name = "syslog";
            syslog = {
              # Promtail expects host:port here, protocol set separately
              listen_address = "${cfg.syslog.address}:${toString cfg.syslog.port}";
              listen_protocol = cfg.syslog.protocol; # "udp" or "tcp"
              idle_timeout = cfg.syslog.idleTimeout;
              label_structured_data = cfg.syslog.labelStructuredData;
              use_incoming_timestamp = cfg.syslog.useIncomingTimestamp;
              labels = cfg.syslog.labels;
            };
            relabel_configs = [
              { source_labels = [ "__syslog_message_hostname" ]; target_label = "syslog_host"; }
              { source_labels = [ "__syslog_message_app_name" ]; target_label = "app"; }
              { source_labels = [ "__syslog_message_severity" ]; target_label = "severity"; }
              { source_labels = [ "__syslog_message_severity" ]; target_label = "level"; }
              { source_labels = [ "__syslog_message_facility" ]; target_label = "facility"; }
              { source_labels = [ "__syslog_connection_ip_address" ]; target_label = "src_ip"; }
            ];
            pipeline_stages = [
              { labels = { env = "homelab"; }; }
              # Example drop rule for extremely chatty syslog senders
              {
                match = {
                  selector = "{job=\"syslog\"} |= \"healthcheck\"";
                  action = "drop";
                };
              }
            ];
          }) ++

          # Additional scrape configs
          cfg.extraScrapeConfigs;
      } cfg.extraConfig;
    };

    # Systemd service resource limits and permissions
    systemd.services.promtail = {
      serviceConfig = {
        # Resource limits for homelab deployment
        MemoryMax = cfg.resources.MemoryMax;
        CPUQuota = cfg.resources.CPUQuota;
        # Security hardening
        NoNewPrivileges = true;
      } // lib.optionalAttrs (cfg.syslog.enable && cfg.syslog.port < 1024) {
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };

      # Service dependencies for journal access and ZFS
      after = [ "systemd-journald.service" ] ++ lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
      wants = [ "systemd-journald.service" ] ++ lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ];
    };

    # Firewall configuration (only allow local access)
    networking.firewall = {
      interfaces.lo.allowedTCPPorts = [ cfg.port ];
    } // lib.optionalAttrs cfg.syslog.enable (
      if cfg.syslog.protocol == "udp" then {
        allowedUDPPorts = [ cfg.syslog.port ];
      } else {
        allowedTCPPorts = [ cfg.syslog.port ];
      }
    );

    # Ensure Promtail state directory exists with correct ownership
    # Only use tmpfiles if not using ZFS dataset (which handles ownership)
    systemd.tmpfiles.rules = lib.mkIf (cfg.zfs.dataset == null) [
      "d ${cfg.dataDir} 0755 promtail promtail -"
    ];

    # Monitoring integration - expose metrics
    # Note: Metrics available at http://127.0.0.1:${port}/metrics for manual Prometheus scraping
  };
}
