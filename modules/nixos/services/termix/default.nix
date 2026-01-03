# Termix - Self-hosted SSH web terminal and server management platform
#
# Termix provides SSH terminal access, tunnel management, remote file manager,
# and server statistics through a modern web interface with native OIDC support.
#
# Reference: https://github.com/Termix-SSH/Termix
# Docs: https://docs.termix.site/

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
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.termix;

  # Import shared type definitions
  sharedTypes = mylib.types;

  cfg = config.modules.services.termix;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;

  hasCentralizedNotifications = notificationsCfg.enable or false;

  # Default port changed from 8080 (conflicts with qbittorrent/tqm) to 8095
  termixPort = cfg.port;

  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-termix.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/termix";

  # Build replication config for preseed
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.termix = {
    enable = lib.mkEnableOption "termix SSH web terminal";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/termix";
      description = "Path to Termix data directory (SQLite database, uploads, config)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "termix";
      description = "User account under which Termix runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "termix";
      description = "Group under which Termix runs.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.uid;
      description = "UID for the Termix service user (from lib/service-uids.nix).";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.gid;
      description = "GID for the Termix service group (from lib/service-uids.nix).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8095;
      description = ''
        Port for the Termix web interface.
        Default changed from upstream 8080 to avoid conflicts with qbittorrent/tqm.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/lukegus/termix:release-1.9.0@sha256:42649d815da4ee2cb71560b04a22641e54d993e05279908711d9056504487feb";
      description = ''
        Full container image name including tag and digest.
        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/lukegus/termix:release-1.9.0@sha256:42649d815da4ee2cb71560b04a22641e54d993e05279908711d9056504487feb";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    # OIDC configuration for PocketID integration
    oidc = {
      enable = lib.mkEnableOption "OIDC authentication via PocketID";

      serverUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "OIDC issuer URL (e.g., https://id.example.com)";
        example = "https://id.holthome.net";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "termix";
        description = "OIDC client ID registered with PocketID";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing OIDC client secret";
      };

      autoRedirect = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically redirect to OIDC provider for login";
      };
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "2.0";
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
        startPeriod = "60s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Termix web interface";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "infrastructure" "termix" "ssh-management" ];
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/termix";
        excludePatterns = lib.mkDefault [
          "**/*.log"
          "**/logs/**"
        ];
      };
      description = "Backup configuration for Termix";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "infrastructure-alerts" ];
        };
        customMessages = {
          failure = "Termix SSH terminal service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Termix service events";
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
        description = "Optional environment file for Restic";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Order of restore methods to attempt.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Assertions for configuration validation
      assertions =
        (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Termix backup.enable requires backup.repository to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Termix preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Termix preseed.enable requires preseed.passwordFile to be set.";
        })
        ++ (lib.optional cfg.oidc.enable {
          assertion = cfg.oidc.serverUrl != "";
          message = "Termix oidc.enable requires oidc.serverUrl to be set.";
        })
        ++ (lib.optional cfg.oidc.enable {
          assertion = cfg.oidc.clientSecretFile != null;
          message = "Termix oidc.enable requires oidc.clientSecretFile to be set.";
        });

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.termix = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = termixPort;
        };

        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # ZFS dataset for persistent storage
      modules.storage.datasets.services.termix = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite database
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Create local user and group
      users.users.${cfg.user} = {
        uid = cfg.uid;
        group = cfg.group;
        isSystemUser = true;
        description = "Termix service user";
        home = "/var/empty";
        createHome = false;
      };

      users.groups.${cfg.group} = {
        gid = cfg.gid;
      };

      # Termix container configuration
      virtualisation.oci-containers.containers.termix = podmanLib.mkContainer "termix" {
        image = cfg.image;
        environment = {
          PORT = toString termixPort;
          TZ = cfg.timezone;
          # Disable SSL - handled by Caddy reverse proxy
          ENABLE_SSL = "false";
        };
        environmentFiles = lib.optional cfg.oidc.enable "/run/termix/oidc.env";
        volumes = [
          "${cfg.dataDir}:/app/data:rw"
        ];
        ports = [
          "127.0.0.1:${toString termixPort}:${toString termixPort}"
        ];
        resources = cfg.resources;
        extraOptions =
          [
            "--pull=newer"
            # Note: Container runs as root internally because the entrypoint script
            # needs to modify nginx config. Security is maintained via:
            # 1. Container isolation
            # 2. Localhost-only port binding (127.0.0.1)
            # 3. OIDC authentication via Caddy reverse proxy
          ]
          ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
            # Use Node.js for healthcheck since container lacks wget/curl
            ''--health-cmd=node -e "fetch('http://127.0.0.1:${toString termixPort}/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"''
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
            "--health-on-failure=${cfg.healthcheck.onFailure}"
          ];
      };

      # Pre-start service to set up OIDC environment
      systemd.services."${config.virtualisation.oci-containers.backend}-termix" = lib.mkMerge [
        {
          serviceConfig = {
            # Create runtime directory for OIDC env file
            RuntimeDirectory = "termix";
            RuntimeDirectoryMode = "0700";
          };
          preStart = lib.mkIf cfg.oidc.enable ''
            # Generate OIDC environment file with secret
            cat > /run/termix/oidc.env << 'EOF'
            OIDC_ENABLED=true
            OIDC_ISSUER_URL=${cfg.oidc.serverUrl}
            OIDC_CLIENT_ID=${cfg.oidc.clientId}
            OIDC_REDIRECT_URI=https://${cfg.reverseProxy.hostName or "termix.local"}/auth/callback
            OIDC_AUTO_REDIRECT=${if cfg.oidc.autoRedirect then "true" else "false"}
            EOF
            echo "OIDC_CLIENT_SECRET=$(cat ${cfg.oidc.clientSecretFile})" >> /run/termix/oidc.env
            chmod 600 /run/termix/oidc.env
          '';
        }
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@termix-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-termix.service" ];
          after = [ "preseed-termix.service" ];
        })
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "termix-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Termix</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Termix SSH web terminal service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Add the preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "termix";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
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
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
