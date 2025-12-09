# Bichon - Self-hosted email archiving system
# https://github.com/rustmailer/bichon
#
# Design Decision: Container-based implementation
# - No native NixOS module available in nixpkgs
# - Upstream only provides container images
# - Rust application with complex dependencies (Tantivy, Native_DB)
#
# Port: 15630 (HTTP)
# Data: /var/lib/bichon (SQLite metadata + Tantivy index + EML storage)
#
# Authentication: SSO via caddySecurity (no native multi-user support)
# The built-in access token auth is single-user only (root), so we skip it
# and use PocketID SSO at the reverse proxy layer instead.
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  sharedTypes = mylib.types;
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  cfg = config.modules.services.bichon;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "bichon";
  bichonPort = 15630;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  domain = config.networking.domain or "local";
  defaultHostname = "bichon.${domain}";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.bichon = {
    enable = lib.mkEnableOption "Bichon email archiving system";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/bichon";
      description = "Path to Bichon data directory (metadata, indexes, and EML storage)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "bichon";
      description = "User account under which Bichon runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "bichon";
      description = "Group under which Bichon runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      # Renovate: datasource=docker depName=rustmailer/bichon
      default = "rustmailer/bichon:0.1.4@sha256:eb09da0f018ad6b0129e5ff320dab64838e75761bad5a249f5e4191e44ab7697";
      description = ''
        Full container image name including tag and digest.
        Note: GHCR not available, using Docker Hub.
      '';
      example = "rustmailer/bichon:0.1.5@sha256:...";
    };

    encryptPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to file containing the encryption password for Bichon.
        CRITICAL: This password cannot be changed after first use.
        Changing it will make all existing encrypted data unreadable.
        Generate with: openssl rand -base64 32
      '';
      example = "/run/secrets/bichon/encrypt-password";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${defaultHostname}";
      description = ''
        Public URL where Bichon is accessible.
        Used for CORS configuration and OAuth2 redirects.
      '';
      example = "https://bichon.example.com";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Bichon log verbosity level.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "1.0";
      };
      description = "Resource limits for the container";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "5s";
        retries = 3;
        startPeriod = "30s";
      };
      description = "Container health check configuration";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Bichon web interface";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "email";
        };
      };
      description = "Log shipping configuration for Bichon logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for Bichon data";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "service-alerts" ];
        };
        customMessages = {
          failure = "Bichon email archiving service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Bichon service events";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        default = "/dev/null";
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = ''
          Order and selection of restore methods to attempt.
          Note: restic intentionally excluded from defaults - offsite restore
          is a manual DR decision when syncoid/local sources are unavailable.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Assertions
      assertions = [
        {
          assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
          message = "Bichon backup.enable requires backup.repository to be set.";
        }
      ];

      # Create system user and group
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        description = "Bichon email archiving service user";
        home = "/var/empty";
      };

      users.groups.${cfg.group} = { };

      # Declare dataset requirements for ZFS isolation
      # OCI containers don't support StateDirectory, so we explicitly set permissions
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite metadata and Tantivy index
        compression = "zstd"; # Good compression for email storage
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Container configuration
      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        environmentFiles = [
          # LoadCredential provides the encryption password securely
          # The preStart script creates an env file from the credential
          "/run/${serviceName}/env"
        ];
        environment = {
          TZ = cfg.timezone;
          # Core configuration
          BICHON_ROOT_DIR = "/data";
          BICHON_HTTP_PORT = toString bichonPort;
          BICHON_BIND_ADDR = "0.0.0.0";
          BICHON_PUBLIC_URL = cfg.publicUrl;
          BICHON_LOG_LEVEL = cfg.logLevel;
          # Disable access token auth - we use caddySecurity SSO instead
          BICHON_ENABLE_ACCESS_TOKEN = "false";
          # Disable ANSI logs for cleaner journal output
          BICHON_ANSI_LOGS = "false";
        };
        volumes = [
          "${cfg.dataDir}:/data:rw"
        ];
        ports = [
          "127.0.0.1:${toString bichonPort}:${toString bichonPort}"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
          "--umask=0027"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Health check using Bichon's status endpoint
          ''--health-cmd=curl -fs http://127.0.0.1:${toString bichonPort}/api/status || exit 1''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Systemd service configuration
      systemd.services."${config.virtualisation.oci-containers.backend}-${serviceName}" = lib.mkMerge [
        {
          # Securely load the encryption password and create env file
          serviceConfig = {
            LoadCredential = [
              "encrypt_password:${cfg.encryptPasswordFile}"
            ];
          };
          preStart = ''
            # Create runtime directory
            install -d -m 700 /run/${serviceName}
            # Create env file with encryption password from credential
            {
              printf "BICHON_ENCRYPT_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/encrypt_password")"
            } > /run/${serviceName}/env
            chmod 600 /run/${serviceName}/env
          '';
        }
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@${serviceName}-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-${serviceName}.service" ];
          after = [ "preseed-${serviceName}.service" ];
        })
      ];

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = bichonPort;
        };

        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "${serviceName}-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Bichon</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Bichon email archiving service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Preseed service for disaster recovery
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        inherit serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        inherit mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        inherit hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
