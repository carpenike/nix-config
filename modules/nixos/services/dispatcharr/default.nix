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
  serviceIds = mylib.serviceUids.dispatcharr;

  cfg = config.modules.services.dispatcharr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  dispatcharrPort = 9191;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-dispatcharr.service";
  celeryServiceName = "${config.virtualisation.oci-containers.backend}-dispatcharr-celery";
  datasetPath = "${storageCfg.datasets.parentDataset}/dispatcharr";

  # Upstream's modular Celery entrypoint runs as container root and writes the
  # Beat schedule in /app. Make only that directory writable, then drop to the
  # stable Dispatcharr UID/GID before executing the untouched upstream script.
  celeryEntrypoint = pkgs.writeTextFile {
    name = "dispatcharr-celery-entrypoint";
    executable = true;
    text = ''#!/usr/bin/env bash
set -euo pipefail

for _ in $(seq 1 120); do
  if [[ -s /data/jwt ]]; then
    chown "$PUID:$PGID" /data/jwt
    chmod 0600 /data/jwt
    break
  fi
  sleep 1
done

if [[ ! -s /data/jwt ]]; then
  echo "Timed out waiting for the Dispatcharr Django secret" >&2
  exit 1
fi

chown "$PUID:$PGID" /app
exec /usr/bin/setpriv \
  --reuid="$PUID" \
  --regid="$PGID" \
  --clear-groups \
  /app/docker/entrypoint.celery.sh
'';
  };

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.dispatcharr = {
    enable = lib.mkEnableOption "dispatcharr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dispatcharr";
      description = "Path to Dispatcharr data directory";
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
      default = "ghcr.io/dispatcharr/dispatcharr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "v0.10.4")
        - Use digest pinning for immutability (e.g., "v0.10.4@sha256:...")
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.

        TODO: Pin to specific version/digest instead of :latest tag (improves operational stability)
      '';
      example = "ghcr.io/dispatcharr/dispatcharr:v0.10.4@sha256:f3ad4f59e6e5e4a...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1g";
        memoryReservation = "512M";
        cpus = "2.0";
      };
      description = "Resource limits for the container";
    };

    metricsPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 9192;
      description = ''
        Host port to publish the Dispatcharr Exporter plugin's Prometheus
        endpoint on. The plugin listens inside the container (default 9192);
        without publishing it here, nothing outside the container can scrape
        it. Leave null when the exporter plugin is not installed.
      '';
    };

    celeryResources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1g";
        memoryReservation = "256M";
        cpus = "2.0";
      };
      description = "Resource limits for the Dispatcharr Celery container";
    };

    # Optional VA-API driver selection for container. When null, libva auto-detects.
    vaapiDriver = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "iHD" "i965" ]);
      default = null;
      description = "VA-API driver name to set inside the container (iHD for modern Intel, i965 for legacy).";
    };

    # Optional VA-API render node. Host-derived rather than hardcoded: render node
    # numbering follows probe order, so renderD128 is NOT reliably the Intel iGPU on
    # multi-GPU hosts. Wire this from the host's hardware profile, e.g.
    #   vaapiDevice = config.modules.common.intelDri.renderNode;
    vaapiDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/dri/renderD129";
      description = ''
        Render node exposed to the container as VAAPI_DEVICE. When null the variable is
        omitted and libva/the transcode profile picks a node on its own.

        The path is evaluated *inside* the container, so it must be a node that
        `accelerationDevices` actually passes in, and it must keep its real host node
        name: iHD resolves the GPU through /sys/class/drm/<node>, which the container
        shares with the host, so renaming the node on the way in points the driver at
        the wrong card.
      '';
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/dri" ];
      description = ''
        Device paths for hardware acceleration (VA-API /dev/dri).

        Default passes entire /dev/dri directory for robust device detection
        across reboots (device node numbers can change). The application will
        automatically select the correct render node.

        Common configurations:
        - Default (recommended): [ "/dev/dri" ]
        - Empty list: CPU-only processing
      '';
      example = [ "/dev/dri" ];
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "300s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Dispatcharr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 9191;
        path = "/api/health";
        labels = {
          service_type = "media_management";
          exporter = "dispatcharr";
          function = "iptv_management";
        };
      };
      description = "Prometheus metrics collection configuration for Dispatcharr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-dispatcharr.service";
        labels = {
          service = "dispatcharr";
          service_type = "media_management";
        };
      };
      description = "Log shipping configuration for Dispatcharr logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "media" "dispatcharr" "iptv" ];
      };
      description = "Backup configuration for Dispatcharr";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Dispatcharr IPTV management failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Dispatcharr service events";
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

    database = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "host.containers.internal";
        description = ''
          PostgreSQL host address.

          Defaults to Podman's host alias (host.containers.internal) so containers
          can reach the host PostgreSQL instance without extra network plumbing.
          Override when pointing Dispatcharr at a remote database or non-standard
          access path.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "dispatcharr";
        description = "Database name";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "dispatcharr";
        description = "Database user";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to file containing database password for the application.

          CRITICAL: Dispatcharr does NOT support POSTGRES_PASSWORD_FILE.
          The password must be injected into the POSTGRES_PASSWORD environment variable at runtime.
          This uses systemd's LoadCredential to securely pass the password.

          Should reference a SOPS secret:
            config.sops.secrets."postgresql/dispatcharr_password".path
        '';
      };
    };

    redis = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "host.containers.internal";
        description = "Redis host address";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Redis port";
      };

      database = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Dedicated Redis database index (0 through 15)";
      };
    };

  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # NOTE: Database requirements are declared at the host level
      # (e.g., in hosts/forge/dispatcharr.nix) using:
      # modules.services.postgresql.databases.dispatcharr
      #
      # This follows the pattern where hosts compose services and declare
      # infrastructure dependencies, while service modules focus on the
      # service implementation itself.

      # Validate configuration
      assertions =
        (lib.optional (cfg.backup != null && cfg.backup.enable) {
          assertion = cfg.backup.repository != null;
          message = "Dispatcharr backup.enable requires backup.repository to be set (use primaryRepo.name from host config).";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Dispatcharr preseed.enable requires preseed.repositoryUrl to be set.";
        })
        ++ (lib.optional cfg.preseed.enable {
          assertion = builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile;
          message = "Dispatcharr preseed.enable requires preseed.passwordFile to be set.";
        })
        ++ (lib.optional (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          assertion = cfg.reverseProxy.hostName != null;
          message = "Dispatcharr reverseProxy.enable requires reverseProxy.hostName to be set.";
        })
        ++ (lib.optional (cfg.vaapiDevice != null) {
          # VAAPI_DEVICE names a path inside the container, so the node has to be
          # passed in -- either directly or via an enclosing directory like /dev/dri.
          assertion = lib.any
            (dev: dev == cfg.vaapiDevice || lib.hasPrefix "${dev}/" cfg.vaapiDevice)
            cfg.accelerationDevices;
          message = "Dispatcharr vaapiDevice (${cfg.vaapiDevice}) is not covered by accelerationDevices (${lib.concatStringsSep ", " cfg.accelerationDevices}); the container cannot see that render node.";
        })
        ++ [
          {
            assertion = config.modules.services.postgresql.enable or false;
            message = "Dispatcharr requires PostgreSQL to be enabled (modules.services.postgresql.enable).";
          }
          {
            assertion = cfg.database.passwordFile != null;
            message = "Dispatcharr database.passwordFile must reference a SOPS secret for POSTGRES_PASSWORD.";
          }
          {
            assertion = cfg.redis.database >= 0 && cfg.redis.database <= 15;
            message = "Dispatcharr redis.database must be between 0 and 15.";
          }
        ];

      # SOPS secret for database password is managed at the host level
      # NOTE: Host must define the secret with mode 0440, owner root, group postgres
      # Example in hosts/forge/secrets.nix:
      #   "postgresql/dispatcharr_password" = {
      #     mode = "0440";
      #     owner = "root";
      #     group = "postgres";
      #   };
      # The passwordFile path is provided via cfg.database.passwordFile
      # The password is injected into POSTGRES_PASSWORD environment variable at container runtime

      # Declare dataset requirements for per-service ZFS isolation
      # This integrates with the storage.datasets module to automatically
      # create tank/services/dispatcharr with appropriate ZFS properties
      # Note: OCI containers don't support StateDirectory, so we explicitly set permissions
      # via tmpfiles by keeping owner/group/mode here
      modules.storage.datasets.services.dispatcharr = {
        mountpoint = cfg.dataDir;
        recordsize = "8K"; # Tuned for PostgreSQL workloads hosted on the shared cluster
        compression = "lz4"; # Fast compression suitable for database workloads
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable automatic snapshots
          # snapdir managed by sanoid module - no longer needed with clone-based backups
        };
        # Ownership matches the container user/group
        owner = cfg.user;
        group = cfg.group;
        mode = "0750"; # Allow group read access for backup systems
      };

      # Configure ZFS snapshots and replication for dispatcharr dataset
      # This is managed per-service to avoid centralized config coupling
      # NOTE: ZFS snapshots and replication for dispatcharr dataset should be configured
      # in the host-level config (e.g., hosts/forge/default.nix), not here.
      # Reason: Replication targets are host-specific (forge → nas-1, luna → nas-2, etc.)
      # Defining them in a shared module would hardcode "forge" in the target path,
      # breaking reusability across different hosts.

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.dispatcharr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = {
          scheme = "http"; # Dispatcharr uses HTTP locally
          host = "127.0.0.1";
          port = dispatcharrPort;
        };

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # Security configuration from shared types
        security = cfg.reverseProxy.security;

        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Create local users to match container UIDs
      # This ensures proper file ownership on the host
      users.users.dispatcharr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = "dispatcharr";
        isSystemUser = true;
        description = "Dispatcharr service user";
        # Add to render group for GPU access
        # Note: Dispatcharr doesn't need NFS media access (IPTV streams only)
        # If you add media library integration later, add: extraGroups = [ "media" ];
        extraGroups = lib.optionals (cfg.accelerationDevices != [ ]) [ "render" ];
      };

      users.groups.dispatcharr = {
        gid = lib.mkDefault (lib.toInt cfg.group);
      };

      # Dispatcharr container configuration
      # NOTE: Dispatcharr uses individual PostgreSQL environment variables (POSTGRES_HOST, POSTGRES_DB, etc.)
      # The password must be injected at runtime via environmentFiles to avoid leaking it in process list
      # Upstream modular mode natively supports external PostgreSQL, Redis, and Celery.
      virtualisation.oci-containers.containers.dispatcharr = podmanLib.mkContainer "dispatcharr" {
        image = cfg.image;
        environmentFiles = [
          # This file is generated by systemd service's preStart with POSTGRES_PASSWORD
          "/run/dispatcharr/env"
        ];
        environment = {
          PUID = cfg.user;
          PGID = cfg.group;
          TZ = cfg.timezone;
          DISPATCHARR_ENV = "modular";
          # PostgreSQL connection configuration
          # Use TCP host connection to avoid Unix socket peer authentication issues
          # The container user "dispatcharr" (UID 569) doesn't exist on the host, causing peer auth to fail
          # 127.0.0.1 inside container is container loopback, not host - use host.containers.internal instead
          POSTGRES_HOST = cfg.database.host;
          POSTGRES_PORT = toString cfg.database.port;
          POSTGRES_DB = cfg.database.name;
          POSTGRES_USER = cfg.database.user;
          # POSTGRES_PASSWORD is provided via environmentFiles (generated in preStart)
          REDIS_HOST = cfg.redis.host;
          REDIS_PORT = toString cfg.redis.port;
          REDIS_DB = toString cfg.redis.database;
          # Logging
          DISPATCHARR_LOG_LEVEL = "info";
        } // (lib.optionalAttrs (cfg.vaapiDriver != null) {
          LIBVA_DRIVER_NAME = cfg.vaapiDriver;
        }) // (lib.optionalAttrs (cfg.vaapiDevice != null) {
          # Render node for VA-API, resolved on the host so it names the real Intel node
          VAAPI_DEVICE = cfg.vaapiDevice;
        }) // (lib.optionalAttrs (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          # Reverse proxy configuration for Django
          # Tells Django to trust X-Forwarded-Host from the proxy
          USE_X_FORWARDED_HOST = "true";
          # Adds the public hostname to Django's allowed hosts list
          ALLOWED_HOSTS = "localhost,127.0.0.1,${cfg.reverseProxy.hostName}";
          # Trusts the public origin for secure (HTTPS) CSRF validation
          CSRF_TRUSTED_ORIGINS = "https://${cfg.reverseProxy.hostName}";
        });
        volumes = [
          # Use ':Z' for SELinux systems to ensure the container can write to the volume
          "${cfg.dataDir}:/data:rw,Z"
        ];
        ports = [
          "${toString dispatcharrPort}:9191"
        ] ++ lib.optional (cfg.metricsPort != null)
          "${toString cfg.metricsPort}:9192";
        resources = cfg.resources;
        extraOptions = [
          # Podman-level umask ensures container process creates files with group-readable permissions
          # This allows restic-backup user (member of dispatcharr group) to read data
          "--umask=0027" # Creates directories with 750 and files with 640
          "--pull=newer" # Automatically pull newer images
          # NOTE: Don't use --user flag here! The dispatcharr container's entrypoint
          # script needs to run as root initially to set up /etc/profile.d and other
          # system files, then it drops privileges to PUID/PGID. Using --user prevents
          # the entrypoint from completing its setup tasks.
          # The container will honor PUID/PGID environment variables for privilege dropping.
        ]
        ++ lib.optionals (cfg.accelerationDevices != [ ]) (
          map (dev: "--device=${dev}:${dev}:rwm") cfg.accelerationDevices
        )
        ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          # Define the health check on the container itself.
          # This allows `podman healthcheck run` to work and updates status in `podman ps`.
          # NOTE: Dispatcharr container doesn't include curl/wget by default, so we use a TCP connection test
          # to verify nginx (port 9191) is responding. This is less precise than HTTP checks but more reliable.
          ''--health-cmd=sh -c 'timeout 3 bash -c "</dev/tcp/127.0.0.1/9191" 2>/dev/null' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          # When unhealthy, take configured action (default: kill so systemd can restart)
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      virtualisation.oci-containers.containers.dispatcharr-celery = podmanLib.mkContainer "dispatcharr-celery" {
        image = cfg.image;
        dependsOn = [ "dispatcharr" ];
        environmentFiles = [ "/run/dispatcharr/env" ];
        environment = {
          PUID = cfg.user;
          PGID = cfg.group;
          TZ = cfg.timezone;
          DISPATCHARR_ENV = "modular";
          DISPATCHARR_PORT = toString dispatcharrPort;
          DISPATCHARR_WEB_HOST = "dispatcharr";
          POSTGRES_HOST = cfg.database.host;
          POSTGRES_PORT = toString cfg.database.port;
          POSTGRES_DB = cfg.database.name;
          POSTGRES_USER = cfg.database.user;
          REDIS_HOST = cfg.redis.host;
          REDIS_PORT = toString cfg.redis.port;
          REDIS_DB = toString cfg.redis.database;
          DISPATCHARR_LOG_LEVEL = "info";
          DJANGO_SETTINGS_MODULE = "dispatcharr.settings";
          PYTHONUNBUFFERED = "1";
          CELERY_NICE_LEVEL = "5";
        };
        volumes = [
          "${cfg.dataDir}:/data:rw,Z"
          "${celeryEntrypoint}:/celery-entrypoint.sh:ro,Z"
        ];
        resources = cfg.celeryResources;
        extraOptions = [
          "--umask=0027"
          "--pull=newer"
          "--entrypoint"
          "/celery-entrypoint.sh"
        ]
        ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=sh -c 'export DJANGO_SECRET_KEY="$(tr -d "\r\n" < /data/jwt)"; output=$(/dispatcharrpy/bin/celery -A dispatcharr inspect ping --timeout 5 2>/dev/null); echo "$output" | grep -q "default@" && echo "$output" | grep -q "dvr@"' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # Add systemd dependencies and notifications
      systemd.services."${config.virtualisation.oci-containers.backend}-dispatcharr" = lib.mkMerge [
        # Add failure notifications via systemd
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@dispatcharr-failure:%n.service" ];
        })
        # Add dependency on the preseed service
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-dispatcharr.service" ];
          after = [ "preseed-dispatcharr.service" ];
        })
        # Add dependency on PostgreSQL and database provisioning
        {
          # Use 'requires' for robustness. If provisioning fails, this service won't start.
          requires = [ "postgresql-provision-databases.service" "redis-default.service" ];
          after = [ "postgresql.service" "postgresql-provision-databases.service" "redis-default.service" ];

          # GPU access is granted by passing accelerationDevices into the container
          # (podman --device), not by a systemd DeviceAllow on this unit: podman runs the
          # container payload in its own cgroup under machine.slice, so a unit-level
          # device filter would never reach it.

          # Securely load the database password using systemd's native credential handling.
          # The password will be available at $CREDENTIALS_DIRECTORY/db_password
          serviceConfig.LoadCredential = [ "db_password:${cfg.database.passwordFile}" ];

          # Generate environment file with POSTGRES_PASSWORD at runtime
          # SECURITY: This implementation prevents password leaks via process list and journal
          preStart = ''
            # Fail fast on any error
            set -euo pipefail

            # Create runtime directory for the environment file
            mkdir -p /run/dispatcharr
            chmod 700 /run/dispatcharr

            # Read the password from the systemd-managed credential file
            # Use printf to avoid leaking the password to the journal if 'set -x' is ever enabled
            printf "POSTGRES_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")" > /run/dispatcharr/env

            # Secure permissions (only root can read)
            chmod 600 /run/dispatcharr/env

            # Verify the environment file was created successfully
            if [ ! -f /run/dispatcharr/env ]; then
              echo "ERROR: Failed to create /run/dispatcharr/env"
              exit 1
            fi

            echo "Successfully created POSTGRES_PASSWORD environment file"
          '';
        }
      ];

      systemd.services."${celeryServiceName}" = lib.mkMerge [
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@dispatcharr-failure:%n.service" ];
        })
        {
          requires = [ "redis-default.service" ];
          after = [ "redis-default.service" ];
          partOf = [ mainServiceUnit ];
        }
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "dispatcharr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Dispatcharr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Dispatcharr IPTV management service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };

      # Note: Backup integration now handled by backup-integration module
      # The backup submodule configuration will be auto-discovered and converted
      # to a Restic job named "service-dispatcharr" with the specified settings

      # Optional: Open firewall for Dispatcharr web UI
      # Disabled by default since forge has firewall.enable = false
      # networking.firewall.allowedTCPPorts = [ dispatcharrPort ];
    })

    # Add the preseed service itself
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "dispatcharr";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig; # Pass the auto-discovered replication config
        datasetProperties = {
          recordsize = "8K"; # Optimal for PostgreSQL databases
          compression = "lz4"; # Fast compression suitable for database workloads
          "com.sun:auto-snapshot" = "true"; # Enable sanoid snapshots for this dataset
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
