# Shared type definitions for standardized service module patterns
# This file provides reusable submodule types that ensure consistency across all service modules
{ lib }:
with lib;
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized metrics collection submodule
  # Services that expose Prometheus metrics should use this type for automatic discovery
  metricsSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "Prometheus metrics collection";

      port = mkOption {
        type = types.port;
        description = "Port where metrics endpoint is exposed";
        example = 9090;
      };

      path = mkOption {
        type = types.str;
        default = "/metrics";
        description = "HTTP path for the metrics endpoint";
        example = "/metrics";
      };

      interface = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Interface the metrics endpoint binds to";
      };

      scrapeInterval = mkOption {
        type = types.str;
        default = "60s";
        description = "How often Prometheus should scrape this target";
        example = "30s";
      };

      scrapeTimeout = mkOption {
        type = types.str;
        default = "10s";
        description = "Timeout for scraping this target";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional static labels to apply to all metrics from this target";
        example = {
          environment = "production";
          team = "infrastructure";
          service_type = "database";
        };
      };

      relabelConfigs = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = "Prometheus relabel configs for advanced metric processing";
        example = [
          {
            source_labels = [ "__name__" ];
            regex = "^go_.*";
            action = "drop";
          }
        ];
      };
    };
  };

  # Standardized logging collection submodule
  # Services that produce logs should use this type for automatic Promtail integration
  loggingSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "log shipping to Loki";

      logFiles = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Log files to ship to Loki";
        example = [ "/var/log/service.log" "/var/log/service-error.log" ];
      };

      journalUnit = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Systemd unit to collect journal logs from";
        example = "myservice.service";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Static labels to apply to log streams";
        example = {
          service = "myservice";
          environment = "production";
        };
      };

      parseFormat = mkOption {
        type = types.enum [ "json" "logfmt" "regex" "multiline" "none" ];
        default = "none";
        description = "Log parsing format for structured log extraction";
      };

      regexConfig = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Regex pattern for custom log parsing (when parseFormat = 'regex')";
      };

      multilineConfig = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            firstLineRegex = mkOption {
              type = types.str;
              description = "Regex to identify the first line of a multiline log entry";
            };
            maxWaitTime = mkOption {
              type = types.str;
              default = "3s";
              description = "Maximum time to wait for additional lines";
            };
          };
        });
        default = null;
        description = "Multiline log configuration (when parseFormat = 'multiline')";
      };
    };
  };

  # Standardized reverse proxy integration submodule
  # Web services should use this type for automatic Caddy registration
  reverseProxySubmodule = types.submodule {
    options = {
      enable = mkEnableOption "reverse proxy integration";

      hostName = mkOption {
        type = types.str;
        description = "FQDN for this service";
        example = "service.holthome.net";
      };

      backend = mkOption {
        type = types.submodule {
          options = {
            scheme = mkOption {
              type = types.enum [ "http" "https" ];
              default = "http";
              description = "Backend protocol";
            };

            host = mkOption {
              type = types.str;
              default = "127.0.0.1";
              description = "Backend host address";
            };

            port = mkOption {
              type = types.port;
              description = "Backend port";
            };

            tls = mkOption {
              type = types.submodule {
                options = {
                  verify = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Verify backend TLS certificate";
                  };

                  sni = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Override TLS Server Name Indication";
                  };

                  caFile = mkOption {
                    type = types.nullOr types.path;
                    default = null;
                    description = "Path to custom CA certificate file";
                  };
                };
              };
              default = {};
              description = "TLS settings for HTTPS backends";
            };
          };
        };
        description = "Structured backend configuration";
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
              description = "Name of environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Basic authentication configuration";
      };

      security = mkOption {
        type = types.submodule {
          options = {
            hsts = mkOption {
              type = types.submodule {
                options = {
                  enable = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Enable HSTS";
                  };

                  maxAge = mkOption {
                    type = types.int;
                    default = 15552000; # 6 months
                    description = "HSTS max-age in seconds";
                  };

                  includeSubDomains = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Include subdomains in HSTS";
                  };

                  preload = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable HSTS preload";
                  };
                };
              };
              default = {};
              description = "HTTP Strict Transport Security settings";
            };

            customHeaders = mkOption {
              type = types.attrsOf types.str;
              default = {};
              description = "Custom security headers";
              example = {
                "X-Frame-Options" = "SAMEORIGIN";
                "X-Content-Type-Options" = "nosniff";
              };
            };
          };
        };
        default = {};
        description = "Security configuration";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Additional Caddy directives for this virtual host";
      };
    };
  };

  # Standardized backup integration submodule
  # Stateful services should use this type for consistent backup policies
  backupSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "backups for this service";

      repository = mkOption {
        type = types.str;
        description = "Backup repository identifier";
        example = "primary";
      };

      paths = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Paths to backup (defaults to service dataDir if empty)";
        example = [ "/var/lib/service" "/etc/service" ];
      };

      frequency = mkOption {
        type = types.enum [ "hourly" "daily" "weekly" ];
        default = "daily";
        description = "Backup frequency";
      };

      retention = mkOption {
        type = types.submodule {
          options = {
            daily = mkOption {
              type = types.int;
              default = 7;
              description = "Number of daily backups to retain";
            };

            weekly = mkOption {
              type = types.int;
              default = 4;
              description = "Number of weekly backups to retain";
            };

            monthly = mkOption {
              type = types.int;
              default = 6;
              description = "Number of monthly backups to retain";
            };
          };
        };
        default = {};
        description = "Backup retention policy";
      };

      preBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run before backup (e.g., database dump)";
      };

      postBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run after backup";
      };

      excludePatterns = mkOption {
        type = types.listOf types.str;
        default = [
          "**/.cache"
          "**/cache"
          "**/*.tmp"
          "**/*.log"
        ];
        description = "Patterns to exclude from backup";
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Tags to apply to backup snapshots";
        example = [ "database" "production" "daily" ];
      };

      useSnapshots = mkOption {
        type = types.bool;
        default = false;
        description = "Use ZFS snapshots for consistent backups";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ZFS dataset for snapshot-based backups";
        example = "tank/services/myservice";
      };
    };
  };

  # Standardized notification integration submodule
  # Services should use this type for consistent alerting
  notificationSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "notifications for this service";

      channels = mkOption {
        type = types.submodule {
          options = {
            onFailure = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for service failures";
              example = [ "gotify-critical" "slack-alerts" ];
            };

            onSuccess = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for successful operations";
            };

            onBackup = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for backup events";
            };

            onHealthCheck = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Notification channels for health check failures";
            };
          };
        };
        default = {};
        description = "Notification channel assignments";
      };

      customMessages = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Custom message templates";
        example = {
          failure = "Service \${serviceName} failed on \${hostname}";
          success = "Service \${serviceName} completed successfully";
        };
      };

      escalation = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            afterMinutes = mkOption {
              type = types.int;
              default = 15;
              description = "Minutes before escalating to additional channels";
            };

            channels = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Additional channels for escalated alerts";
            };
          };
        });
        default = null;
        description = "Alert escalation configuration";
      };
    };
  };

  # Standardized container resource management submodule
  # Containerized services should use this type for consistent resource limits
  containerResourcesSubmodule = types.submodule {
    options = {
      memory = mkOption {
        type = types.str;
        description = "Memory limit (e.g., '256m', '2g')";
        example = "512m";
      };

      memoryReservation = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Memory soft limit/reservation";
        example = "256m";
      };

      cpus = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU limit in cores (e.g., '0.5', '2')";
        example = "1.0";
      };

      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU quota percentage (e.g., '50%')";
        example = "75%";
      };

      oomKillDisable = mkOption {
        type = types.bool;
        default = false;
        description = "Disable OOM killer for this container";
      };

      swap = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Swap limit (e.g., '512m')";
      };
    };
  };

  # Standardized systemd resource management submodule
  # Native systemd services should use this type for consistent resource limits
  systemdResourcesSubmodule = types.submodule {
    options = {
      MemoryMax = mkOption {
        type = types.str;
        description = "Maximum memory usage (systemd directive)";
        example = "1G";
      };

      MemoryReservation = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Memory soft limit/reservation (systemd directive)";
        example = "512M";
      };

      CPUQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CPU quota percentage (systemd directive)";
        example = "50%";
      };

      CPUWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "CPU scheduling weight (systemd directive)";
        example = 100;
      };

      IOWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "IO scheduling weight (systemd directive)";
        example = 100;
      };
    };
  };
}
