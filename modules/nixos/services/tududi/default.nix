{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  # Import shared type definitions
  sharedTypes = mylib.types;
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.tududi;

  cfg = config.modules.services.tududi;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  tududiPort = 3002;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-tududi.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/tududi";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.tududi = {
    enable = lib.mkEnableOption "tududi";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tududi";
      description = "Path to Tududi data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = toString serviceIds.uid;
      description = "User ID to own the data directory (from lib/service-uids.nix)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = toString serviceIds.gid;
      description = "Group ID to own the data directory (from lib/service-uids.nix)";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "chrisvel/tududi:latest@sha256:5212ca3fb5309cab626cd3b3f0f85182685b4a6df4d1030b18349824255057a5";
      description = ''
        Full container image name including tag and digest.

        Best practices:
        - Pin to specific version tags with digest for immutability
        - Use Renovate bot to automate version updates

        Official image: https://hub.docker.com/r/chrisvel/tududi
      '';
      example = "chrisvel/tududi:v1.0.0@sha256:...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    adminEmail = lib.mkOption {
      type = lib.types.str;
      default = "ryan@ryanholt.net";
      description = "Initial admin user email address";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to file containing initial admin password.
        Should reference a SOPS secret:
          config.sops.secrets."tududi/admin_password".path
      '';
    };

    sessionSecretFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to file containing Django session secret.
        Should reference a SOPS secret:
          config.sops.secrets."tududi/session_secret".path
      '';
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
        timeout = "10s";
        retries = 3;
        startPeriod = "120s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Tududi web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 3002;
        path = "/";
        labels = {
          service_type = "productivity";
          exporter = "tududi";
          function = "task_management";
        };
      };
      description = "Prometheus metrics collection configuration for Tududi";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-tududi.service";
        labels = {
          service = "tududi";
          service_type = "productivity";
        };
      };
      description = "Log shipping configuration for Tududi logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "productivity" "tududi" "tasks" ];
        # CRITICAL: Enable ZFS snapshots for SQLite database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/tududi";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/cache/**"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Tududi";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "system-alerts" ];
        };
        customMessages = {
          failure = "Tududi productivity service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Tududi service events";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds. Examples:
          - [ "syncoid" "local" "restic" ] - Default, try replication first
          - [ "local" "restic" ] - Skip replication, try local snapshots first
          - [ "restic" ] - Restic-only (for air-gapped systems)
          - [ "local" "restic" "syncoid" ] - Local-first for quick recovery
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Validate configuration
      assertions =
        (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Tududi backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Tududi preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Tududi preseed.enable requires preseed.passwordFile to be set.";
        })
        ++ (lib.optional (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          assertion = cfg.reverseProxy.hostName != null;
          message = "Tududi reverseProxy.enable requires reverseProxy.hostName to be set.";
        })
        ++ [
          {
            assertion = builtins.isPath cfg.adminPasswordFile || builtins.isString cfg.adminPasswordFile;
            message = "Tududi adminPasswordFile must reference a SOPS secret.";
          }
          {
            assertion = builtins.isPath cfg.sessionSecretFile || builtins.isString cfg.sessionSecretFile;
            message = "Tududi sessionSecretFile must reference a SOPS secret.";
          }
        ];

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.tududi = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = tududiPort;
        };

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # Security configuration from shared types
        security = cfg.reverseProxy.security;

        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Declare dataset requirements for per-service ZFS isolation
      modules.storage.datasets.services.tududi = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite database
        compression = "lz4"; # Fast compression suitable for database workloads
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Create local users to match container UIDs
      users.users.tududi = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = "tududi";
        isSystemUser = true;
        description = "Tududi service user";
      };

      users.groups.tududi = {
        gid = lib.mkDefault (lib.toInt cfg.group);
      };

      # Tududi container configuration
      virtualisation.oci-containers.containers.tududi = podmanLib.mkContainer "tududi" {
        image = cfg.image;
        environmentFiles = [
          # Environment file with sensitive secrets
          "/run/tududi/env"
        ];
        environment = {
          PUID = cfg.user;
          PGID = cfg.group;
          TZ = cfg.timezone;
          TUDUDI_USER_EMAIL = cfg.adminEmail;
          TUDUDI_UPLOAD_PATH = "/app/backend/uploads";
        } // (lib.optionalAttrs (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          TUDUDI_ALLOWED_ORIGINS = "https://${cfg.reverseProxy.hostName}";
        });
        volumes = [
          "${cfg.dataDir}/db:/app/backend/db:rw,Z"
          "${cfg.dataDir}/uploads:/app/backend/uploads:rw,Z"
        ];
        ports = [
          "${toString tududiPort}:3002"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--umask=0027"
          "--pull=newer"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:3002/)" = 200 ]' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Add systemd dependencies and notifications
      systemd.services."${config.virtualisation.oci-containers.backend}-tududi" = lib.mkMerge [
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@tududi-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-tududi.service" ];
          after = [ "preseed-tududi.service" ];
        })
        # Securely load secrets using systemd's native credential handling
        {
          serviceConfig.LoadCredential = [
            "admin_password:${cfg.adminPasswordFile}"
            "session_secret:${cfg.sessionSecretFile}"
          ];

          # Generate environment file with secrets at runtime
          preStart = ''
            set -euo pipefail

            mkdir -p /run/tududi
            chmod 700 /run/tududi

            # Create environment file with secrets
            {
              printf "TUDUDI_USER_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
              printf "TUDUDI_SESSION_SECRET=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/session_secret")"
            } > /run/tududi/env

            chmod 600 /run/tududi/env

            if [ ! -f /run/tududi/env ]; then
              echo "ERROR: Failed to create /run/tududi/env"
              exit 1
            fi

            # Create data subdirectories
            mkdir -p ${cfg.dataDir}/db ${cfg.dataDir}/uploads
            chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
            chmod 750 ${cfg.dataDir}/db ${cfg.dataDir}/uploads

            echo "Successfully created Tududi environment file"
          '';
        }
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "tududi-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Tududi</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Tududi productivity service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Add the preseed service itself
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "tududi";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "lz4";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
