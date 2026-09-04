# Gatus black-box monitoring service module
#
# This module wraps the native NixOS Gatus service with homelab-specific patterns:
# - Contributory endpoint system (services opt-in via contributions)
# - ZFS storage integration for SQLite persistence
# - Caddy reverse proxy with internal-only access
# - Preseed/DR capability
# - Standard monitoring, backup, and alerting integrations
#
# Architecture Decision: Gatus replaces Uptime Kuma as the black-box monitoring solution.
# Gatus is YAML-config-based, lightweight, and has native Prometheus metrics.
#
# Usage Pattern:
#   Services contribute endpoints via:
#     modules.services.gatus.contributions.<serviceName> = {
#       name = "My Service";
#       url = "https://myservice.example.com/health";
#       interval = "60s";
#       conditions = [ "[STATUS] == 200" ];
#     };
#
{ config, lib, mylib, ... }:

let
  cfg = config.modules.services.gatus;
  serviceName = "gatus";

  # Import shared types for standard submodules
  sharedTypes = mylib.types;

  # Endpoint contribution submodule - services can register themselves
  endpointSubmodule = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Display name for this endpoint in the status page";
        example = "Plex Media Server";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "Services";
        description = "Group to display this endpoint under";
        example = "Media";
      };

      url = lib.mkOption {
        type = lib.types.str;
        description = "URL to monitor (HTTP, TCP, ICMP, DNS, etc.)";
        example = "https://plex.holthome.net/web/index.html";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "How often to check this endpoint";
        example = "30s";
      };

      conditions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "[STATUS] == 200" ];
        description = ''
          Gatus conditions to evaluate. Common patterns:
          - "[STATUS] == 200" - HTTP status code check
          - "[RESPONSE_TIME] < 500" - Response time in ms
          - "[BODY] == pat(*healthy*)" - Body contains pattern
          - "[CONNECTED] == true" - TCP/ICMP connectivity
          - "[DNS_RCODE] == NOERROR" - DNS resolution check
        '';
        example = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 1000"
        ];
      };

      alerts = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.str;
              default = "pushover";
              description = "Alert provider type";
            };
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether alerting is enabled for this endpoint";
            };
            failureThreshold = lib.mkOption {
              type = lib.types.int;
              default = 3;
              description = "Number of consecutive failures before alerting";
            };
            successThreshold = lib.mkOption {
              type = lib.types.int;
              default = 2;
              description = "Number of consecutive successes to resolve alert";
            };
            sendOnResolved = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Send notification when endpoint recovers";
            };
            description = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Custom description for this alert";
            };
          };
        });
        default = [{ }]; # Default single pushover alert
        description = "Alert configurations for this endpoint";
      };

      client = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            insecure = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Skip TLS certificate verification";
            };
            timeout = lib.mkOption {
              type = lib.types.str;
              default = "10s";
              description = "Request timeout";
            };
          };
        });
        default = null;
        description = "HTTP client configuration overrides";
      };

      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this endpoint is enabled";
      };

      # Additional Gatus endpoint options can be added as raw attrs
      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Additional Gatus endpoint configuration options";
        example = {
          method = "POST";
          body = "{}";
          headers = { "Content-Type" = "application/json"; };
        };
      };
    };
  });

  # Convert contributions to Gatus endpoints config
  contributionsToEndpoints = lib.mapAttrsToList
    (_serviceName: contrib:
      lib.filterAttrs (_n: v: v != null) ({
        name = contrib.name;
        group = contrib.group;
        url = contrib.url;
        interval = contrib.interval;
        conditions = contrib.conditions;
        alerts = map
          (a: lib.filterAttrs (_n: v: v != null) {
            type = a.type;
            enabled = a.enabled;
            failure-threshold = a.failureThreshold;
            success-threshold = a.successThreshold;
            send-on-resolved = a.sendOnResolved;
            description = a.description;
          })
          contrib.alerts;
        client =
          if contrib.client != null then {
            insecure = contrib.client.insecure;
            timeout = contrib.client.timeout;
          } else null;
        enabled = contrib.enabled;
      } // contrib.extraConfig))
    (lib.filterAttrs (_: c: c.enabled) cfg.contributions);

in
{
  options.modules.services.gatus = {
    enable = lib.mkEnableOption "Gatus black-box monitoring service";

    # Contribution system - services register their endpoints here
    contributions = lib.mkOption {
      type = lib.types.attrsOf endpointSubmodule;
      default = { };
      description = ''
        Services can register themselves for monitoring by adding entries here.
        Each contribution becomes a Gatus endpoint.

        Example in a service module:
          modules.services.gatus.contributions.plex = {
            name = "Plex Media Server";
            group = "Media";
            url = "http://localhost:32400/web/index.html";
            interval = "60s";
            conditions = [ "[STATUS] == 200" ];
          };
      '';
      example = lib.literalExpression ''
        {
          plex = {
            name = "Plex";
            group = "Media";
            url = "https://plex.holthome.net/web/index.html";
            conditions = [ "[STATUS] == 200" ];
          };
        }
      '';
    };

    # Storage configuration
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/gatus";
      description = "Directory for Gatus data (SQLite database)";
    };

    # Network configuration
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for Gatus web interface and API";
    };

    # Alerting configuration
    alerting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          pushover = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "Pushover alerting";

                # One env file, not two secret files. Gatus 5.x substitutes
                # only $VAR / ${VAR} in its config — it has no file-based
                # secret loading — so the values have to arrive as real
                # environment variables of the gatus process itself.
                #
                # The previous shape took two raw secret paths, loaded them
                # with LoadCredential and `export`ed them from preStart. That
                # cannot work: preStart is its own process, and its exports
                # die with it. Gatus interpolated empty strings and refused
                # every alert with "the provider wasn't configured properly"
                # for months, across every endpoint, while the dashboard kept
                # showing green.
                environmentFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  example = "config.sops.templates.\"gatus-pushover-env\".path";
                  description = ''
                    Path to an EnvironmentFile defining GATUS_PUSHOVER_TOKEN
                    and GATUS_PUSHOVER_USER. Read by systemd as root before
                    dropping to the gatus user, so it must not be world
                    readable and must never be in the Nix store.
                  '';
                };

                priority = lib.mkOption {
                  type = lib.types.int;
                  default = 1;
                  description = "Pushover notification priority (-2 to 2)";
                };

                sound = lib.mkOption {
                  type = lib.types.str;
                  default = "siren";
                  description = "Pushover notification sound";
                };

                resolvedPriority = lib.mkOption {
                  type = lib.types.int;
                  default = 0;
                  description = "Priority for resolved notifications";
                };
              };
            };
            default = { };
            description = "Pushover alerting configuration";
          };
        };
      };
      default = { };
      description = "Alerting provider configuration";
    };

    # Status page customization
    ui = lib.mkOption {
      type = lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
            default = "Service Status";
            description = "Title displayed on the status page";
          };

          header = lib.mkOption {
            type = lib.types.str;
            default = "Status";
            description = "Header text on the status page";
          };

          logo = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "URL to custom logo image";
          };

          link = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "URL the logo links to";
          };

          buttons = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption { type = lib.types.str; description = "Button label"; };
                link = lib.mkOption { type = lib.types.str; description = "Button URL"; };
              };
            });
            default = [ ];
            description = "Custom buttons to display on the status page";
          };
        };
      };
      default = { };
      description = "Status page UI customization";
    };

    # Storage backend configuration
    storage = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum [ "sqlite" "memory" "postgres" ];
            default = "sqlite";
            description = "Storage backend type";
          };

          path = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/gatus/data.db";
            description = "Path to SQLite database file (only used when type = sqlite)";
          };
        };
      };
      default = { };
      description = "Storage backend configuration";
    };

    # Additional settings (merged with generated config)
    extraSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional Gatus settings to merge with generated config";
    };

    # Standardized integrations
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Gatus web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = cfg.port;
        path = "/metrics";
        labels = {
          service = "gatus";
          service_type = "monitoring";
          function = "blackbox";
        };
      };
      description = "Prometheus metrics configuration (Gatus has native /metrics endpoint)";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for Gatus data";
    };

    # Preseed/DR capability
    preseed = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "automatic restore before service start";

          repositoryUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "URL to Restic repository for preseed restore";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Restic repository password";
          };

          restoreMethods = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" ];
            description = "Ordered list of restore methods to attempt";
          };
        };
      };
      default = { };
      description = "Preseed/DR restore configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Fail the build rather than repeat the silent version of this. Alerting
    # that cannot send looks exactly like alerting with nothing to say, and
    # that is precisely how the previous breakage survived unnoticed.
    assertions = [{
      assertion = !cfg.alerting.pushover.enable
        || cfg.alerting.pushover.environmentFile != null;
      message = ''
        modules.services.gatus.alerting.pushover.environmentFile must be set
        when Pushover alerting is enabled. Gatus substitutes only environment
        variables, so GATUS_PUSHOVER_TOKEN and GATUS_PUSHOVER_USER have to be
        delivered to the process through an EnvironmentFile.
      '';
    }];

    # Use native NixOS Gatus service
    services.gatus = {
      enable = true;

      # Upstream sets EnvironmentFile= from this, so GATUS_PUSHOVER_TOKEN and
      # GATUS_PUSHOVER_USER exist in gatus's own environment when it expands
      # ${...} in the alerting config below.
      environmentFile = cfg.alerting.pushover.environmentFile;

      settings = lib.mkMerge [
        # Core settings
        {
          web.port = cfg.port;
          metrics = cfg.metrics != null && cfg.metrics.enable;

          storage = {
            type = cfg.storage.type;
          } // lib.optionalAttrs (cfg.storage.type == "sqlite") {
            path = cfg.storage.path;
          };

          ui = {
            title = cfg.ui.title;
            header = cfg.ui.header;
          } // lib.optionalAttrs (cfg.ui.logo != null) {
            logo = cfg.ui.logo;
          } // lib.optionalAttrs (cfg.ui.link != null) {
            link = cfg.ui.link;
          } // lib.optionalAttrs (cfg.ui.buttons != [ ]) {
            buttons = cfg.ui.buttons;
          };

          # Aggregated endpoints from contributions
          endpoints = contributionsToEndpoints;
        }

        # Pushover alerting configuration
        (lib.mkIf cfg.alerting.pushover.enable {
          alerting.pushover = {
            application-token = "\${GATUS_PUSHOVER_TOKEN}";
            user-key = "\${GATUS_PUSHOVER_USER}";
            default-alert = {
              enabled = true;
              failure-threshold = 3;
              success-threshold = 2;
              send-on-resolved = true;
            };
            priority = cfg.alerting.pushover.priority;
            sound = cfg.alerting.pushover.sound;
            resolved-priority = cfg.alerting.pushover.resolvedPriority;
          };
        })

        # User-provided extra settings
        cfg.extraSettings
      ];
    };

    # Override systemd service for ZFS integration
    systemd.services.gatus = {
      # Wait for ZFS datasets
      after = [ "local-fs.target" "zfs-mount.service" ];
      wants = [ "zfs-mount.service" ];

      # Override DynamicUser for persistent storage
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = serviceName;
        Group = serviceName;

        # Security hardening
        ReadWritePaths = [ cfg.dataDir ];
      };

      # No preStart. Secrets reach gatus through services.gatus.environmentFile
      # below, which upstream turns into EnvironmentFile= on this unit — the
      # only mechanism that puts a variable in the environment of the process
      # that actually reads it.
    };

    # Create gatus user/group
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = lib.mkForce "/var/empty";
      description = "Gatus monitoring service user";
    };

    users.groups.${serviceName} = { };

    # Caddy reverse proxy integration
    modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = cfg.reverseProxy.backend;
      caddySecurity = cfg.reverseProxy.caddySecurity or null;
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # Firewall - only allow localhost access (internal service)
    networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
  };
}
