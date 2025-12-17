# Enclosed - Self-hostable encrypted note sharing
# https://enclosed.cc / https://github.com/CorentinTh/enclosed
#
# Design Decision: Container-based implementation
# - No native NixOS module available in nixpkgs
# - Upstream only provides container images
# - Simple stateless service with file-based storage at /app/.data
#
# Port: 8787 (HTTP)
# Data: /app/.data (SQLite database + encrypted attachments)
# Security: Client-side AES-GCM encryption - server never sees plaintext
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
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.enclosed;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "enclosed";
  enclosedPort = 8787;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.enclosed = {
    enable = lib.mkEnableOption "Enclosed encrypted note sharing service";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/enclosed";
      description = "Path to Enclosed data directory (maps to /app/.data in container)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "enclosed";
      description = "User account under which Enclosed runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "enclosed";
      description = "Group under which Enclosed runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/corentinth/enclosed:1.9.2@sha256:be7576d6d1074698bb572162eaa5fdefaabfb1b70bcb4a936d1f46ab07051285";
      description = ''
        Full container image name including tag and digest.
        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/corentinth/enclosed:1.9.2@sha256:...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    maxPayloadSize = lib.mkOption {
      type = lib.types.int;
      default = 52428800; # 50 MB
      description = ''
        Maximum size of encrypted payload (note + attachments) in bytes.
        Default is 50 MB (52428800 bytes).
        Set to 0 to disable limit (not recommended).
      '';
      example = 104857600; # 100 MB
    };

    storageQuota = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5G";
      description = ''
        ZFS quota for the Enclosed data directory.
        Provides hard limit to prevent filesystem abuse.
        Set to null to disable quota (not recommended for public services).
      '';
      example = "10G";
    };

    # UX/Policy settings for note creation defaults
    settings = {
      defaultTtlSeconds = lib.mkOption {
        type = lib.types.enum [ 3600 86400 604800 2592000 ];
        default = 86400; # 1 day
        description = ''
          Default expiration time for new notes in seconds.
          Users can still change this when creating a note.
          Options: 3600 (1 hour), 86400 (1 day), 604800 (1 week), 2592000 (1 month)
        '';
        example = 604800; # 1 week
      };

      defaultDeleteAfterReading = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Default state of "delete after reading" checkbox for new notes.
          When enabled, notes self-destruct after first view.
        '';
      };

      allowNoExpiration = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Allow users to create notes that never expire.
          Security consideration: disabled by default to prevent orphaned data.
        '';
      };
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "256M";
        memoryReservation = "128M";
        cpus = "0.5";
      };
      description = "Resource limits for the container (Enclosed is very lightweight)";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "30s";
      };
      description = "Container health check configuration";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Enclosed web interface";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "notes";
        };
      };
      description = "Log shipping configuration for Enclosed logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for Enclosed data";
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
          failure = "Enclosed note sharing service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Enclosed service events";
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
          message = "Enclosed backup.enable requires backup.repository to be set.";
        }
      ];

      # Create system user and group
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        description = "Enclosed service user";
        home = "/var/empty";
      };

      users.groups.${cfg.group} = { };

      # Declare dataset requirements for ZFS isolation
      # OCI containers don't support StateDirectory, so we explicitly set permissions
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for small encrypted files and SQLite
        compression = "zstd"; # Good compression for encrypted data
        properties = {
          "com.sun:auto-snapshot" = "true";
        } // lib.optionalAttrs (cfg.storageQuota != null) {
          # ZFS quota provides hard limit against abuse
          quota = cfg.storageQuota;
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Container configuration
      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        environment = {
          TZ = cfg.timezone;
          # Size limits
          NOTES_MAX_ENCRYPTED_PAYLOAD_LENGTH = toString cfg.maxPayloadSize;
          # UX defaults for note creation
          PUBLIC_DEFAULT_NOTE_TTL_SECONDS = toString cfg.settings.defaultTtlSeconds;
          PUBLIC_DEFAULT_DELETE_NOTE_AFTER_READING = lib.boolToString cfg.settings.defaultDeleteAfterReading;
          PUBLIC_IS_SETTING_NO_EXPIRATION_ALLOWED = lib.boolToString cfg.settings.allowNoExpiration;
        };
        volumes = [
          "${cfg.dataDir}:/app/.data:rw"
        ];
        ports = [
          "127.0.0.1:${toString enclosedPort}:8787"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
          "--umask=0027"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Simple HTTP health check
          ''--health-cmd=wget --no-verbose --spider http://127.0.0.1:8787/ || exit 1''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Systemd service configuration
      systemd.services."${config.virtualisation.oci-containers.backend}-${serviceName}" = lib.mkMerge [
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
          port = enclosedPort;
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
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Enclosed</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Enclosed note sharing service has entered a failed state.

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
