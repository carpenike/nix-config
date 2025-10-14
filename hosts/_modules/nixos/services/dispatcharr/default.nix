{
  lib,
  pkgs,
  config,
  podmanLib,
  ...
}:
let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  cfg = config.modules.services.dispatcharr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  dispatcharrPort = 9191;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-dispatcharr.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/dispatcharr";

  # Custom entrypoint wrapper that skips embedded PostgreSQL when using external database
  # This wraps the original Dispatcharr entrypoint to conditionally disable the embedded
  # PostgreSQL service when POSTGRES_HOST is set to a non-localhost value
  # NOTE: Use writeTextFile instead of writeShellScript because the container needs /bin/bash shebang, not Nix store bash
  customEntrypoint = pkgs.writeTextFile {
    name = "dispatcharr-entrypoint-wrapper";
    executable = true;
    text = ''#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Dispatcharr Entrypoint Wrapper"
echo "   POSTGRES_HOST: ''${POSTGRES_HOST:-not set}"

# Check if we're using an external PostgreSQL database
# Detect external DB if POSTGRES_HOST is set to a host address (not localhost)
if [ "''${POSTGRES_HOST}" != "localhost" ] && [ -n "''${POSTGRES_HOST}" ]; then
  echo "✅ External PostgreSQL detected (''${POSTGRES_HOST})"
  echo "   Disabling embedded PostgreSQL initialization..."

  # Create a modified entrypoint that skips PostgreSQL
  cp /app/docker/entrypoint.sh /tmp/entrypoint-modified.sh
  chmod +x /tmp/entrypoint-modified.sh

  # Comment out the PostgreSQL initialization in the init script sourcing (appears twice)
  sed -i 's|^\. /app/docker/init/02-postgres\.sh$|# DISABLED: . /app/docker/init/02-postgres.sh|g' /tmp/entrypoint-modified.sh

  # Comment out the entire PostgreSQL startup block (lines 110-119)
  # This includes: "Starting Postgres...", pg_ctl start, until loop, postgres_pid, pids+=
  sed -i '/^echo "Starting Postgres\.\.\."$/,/^pids+=("\$postgres_pid")$/ s|^|# DISABLED: |' /tmp/entrypoint-modified.sh

  # Comment out ensure_utf8_encoding call
  sed -i 's|^ensure_utf8_encoding$|# DISABLED: ensure_utf8_encoding|g' /tmp/entrypoint-modified.sh

  # Fix nginx.conf to specify both user and group (01-user-setup.sh creates group "dispatch" but user "$POSTGRES_USER")
  # After 01-user-setup.sh runs, it sets: user dispatcharr;
  # But the group is named "dispatch", not "dispatcharr", causing nginx to fail with getgrnam error
  # Insert fix right after line 107 (after ". /app/docker/init/03-init-dispatcharr.sh")
  echo "   Fixing nginx.conf group specification..."
  sed -i '107 a\
# Fix nginx.conf to use correct group name\
sed -i "s|^user ''\${POSTGRES_USER};|user ''\${POSTGRES_USER} dispatch;|" /etc/nginx/nginx.conf 2>/dev/null || true' /tmp/entrypoint-modified.sh

  echo "   Modified entrypoint created successfully"

  # Validate the modified entrypoint syntax before executing
  if ! bash -n /tmp/entrypoint-modified.sh; then
    echo "❌ Syntax error in modified entrypoint script!"
    echo "   First 50 lines of modified script:"
    head -50 /tmp/entrypoint-modified.sh | cat -n
    exit 1
  fi

  # Execute the modified entrypoint
  echo "🚀 Starting Dispatcharr with external PostgreSQL..."
  exec /tmp/entrypoint-modified.sh "$@"
else
  echo "ℹ️  Using embedded PostgreSQL (localhost)"
  # Execute the original entrypoint
  exec /app/docker/entrypoint.sh "$@"
fi
'';
  };

  # Recursively find the replication config from the most specific dataset path upwards.
  # This allows a service dataset (e.g., tank/services/dispatcharr) to inherit replication
  # config from a parent dataset (e.g., tank/services) without duplication.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        # Check if replication is defined for the current path (datasets are flat keys, not nested)
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        # Determine the parent path for recursion
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      # If found, return it. Otherwise, recurse to the parent.
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  # Execute the search for the current service's dataset
  foundReplication = findReplication datasetPath;

  # Build the final config attrset to pass to the preseed service.
  # This only evaluates if replication is found and sanoid is enabled, preventing errors.
  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        # Get the suffix, e.g., "dispatcharr" from "tank/services/dispatcharr" relative to "tank/services"
        datasetSuffix = lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        # Construct the full target dataset path, e.g., "backup/forge/services/dispatcharr"
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        # Pass through sendOptions and recvOptions for syncoid
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
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
      default = "569";
      description = "User ID to own the data directory (dispatcharr:dispatcharr in container)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "569";
      description = "Group ID to own the data directory";
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
      '';
      example = "ghcr.io/dispatcharr/dispatcharr:v0.10.4@sha256:f3ad4f59e6e5e4a...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "1g";
            description = "Memory limit for the container (Python/Django application)";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "2.0";
            description = "CPU limit for the container";
          };
        };
      });
      default = { memory = "1g"; cpus = "2.0"; };
      description = "Resource limits for the container";
    };

    healthcheck = {
      enable = lib.mkEnableOption "container health check";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Frequency of health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for each health check.";
      };
      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy.";
      };
      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "300s";
        description = "Grace period for the container to initialize before failures are counted. Allows time for DB migrations and first-run initialization.";
      };
    };

    backup = {
      enable = lib.mkEnableOption "backup for Dispatcharr data";
      repository = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the Restic repository to use for backups. Should reference primaryRepo.name from host config.";
      };
    };

    notifications = {
      enable = lib.mkEnableOption "failure notifications for the Dispatcharr service";
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
        default = "localhost";
        description = "PostgreSQL host address";
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

    reverseProxy = {
      enable = lib.mkEnableOption "reverse proxy integration";
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The FQDN used to access Dispatcharr via the reverse proxy. Required for proper CSRF and host header validation.";
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
        (lib.optional cfg.backup.enable {
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
        ++ (lib.optional cfg.reverseProxy.enable {
          assertion = cfg.reverseProxy.hostName != null;
          message = "Dispatcharr reverseProxy.enable requires reverseProxy.hostName to be set.";
        })
        ++ [
          {
            assertion = config.modules.services.postgresql.enable or false;
            message = "Dispatcharr requires PostgreSQL to be enabled (modules.services.postgresql.enable).";
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
    modules.storage.datasets.services.dispatcharr = {
      mountpoint = cfg.dataDir;
      recordsize = "8K";  # Optimal for PostgreSQL databases (uses embedded postgres)
      compression = "lz4";  # Fast compression suitable for database workloads
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
        snapdir = "visible";  # Make .zfs/snapshot accessible for backups
      };
      # Ownership matches the container user/group
      owner = "dispatcharr";
      group = "dispatcharr";
      mode = "0700";  # Restrictive permissions
    };

    # Create local users to match container UIDs
    # This ensures proper file ownership on the host
    users.users.dispatcharr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = "dispatcharr";
      isSystemUser = true;
      description = "Dispatcharr service user";
      # Note: Dispatcharr doesn't need NFS media access (IPTV streams only)
      # If you add media library integration later, add: extraGroups = [ "media" ];
    };

    users.groups.dispatcharr = {
      gid = lib.mkDefault (lib.toInt cfg.group);
    };

    # Dispatcharr container configuration
    # NOTE: Dispatcharr uses individual PostgreSQL environment variables (POSTGRES_HOST, POSTGRES_DB, etc.)
    # The password must be injected at runtime via environmentFiles to avoid leaking it in process list
    # CRITICAL: Uses custom entrypoint wrapper to disable embedded PostgreSQL when using external database
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
        # PostgreSQL connection configuration
        # Use TCP host connection to avoid Unix socket peer authentication issues
        # The container user "dispatcharr" (UID 569) doesn't exist on the host, causing peer auth to fail
        # 127.0.0.1 inside container is container loopback, not host - use host.containers.internal instead
        POSTGRES_HOST = "host.containers.internal";  # Podman DNS alias for host
        POSTGRES_PORT = "5432";
        POSTGRES_DB = cfg.database.name;
        POSTGRES_USER = cfg.database.user;
        # POSTGRES_PASSWORD is provided via environmentFiles (generated in preStart)
        # Redis configuration (embedded Redis via s6-overlay)
        REDIS_HOST = "localhost";
        CELERY_BROKER_URL = "redis://localhost:6379/0";
        CELERY_RESULT_BACKEND_URL = "redis://localhost:6379/0";
        # Logging
        DISPATCHARR_LOG_LEVEL = "info";
      } // (lib.optionalAttrs cfg.reverseProxy.enable {
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
        # Mount custom entrypoint wrapper to disable embedded PostgreSQL
        # Use :Z for SELinux compatibility to allow container to execute the script
        "${customEntrypoint}:/entrypoint-wrapper.sh:ro,Z"
      ];
      ports = [
        "${toString dispatcharrPort}:9191"
      ];
      resources = cfg.resources;
      extraOptions = [
        "--pull=newer"  # Automatically pull newer images
        # Override the container's entrypoint to use our custom wrapper
        # CRITICAL: Must use two separate list items for proper option ordering
        # The wrapper script is bind-mounted as executable at /entrypoint-wrapper.sh
        "--entrypoint"
        "/entrypoint-wrapper.sh"
        # NOTE: Don't use --user flag here! The dispatcharr container's entrypoint
        # script needs to run as root initially to set up /etc/profile.d and other
        # system files, then it drops privileges to PUID/PGID. Using --user prevents
        # the entrypoint from completing its setup tasks.
        # The container will honor PUID/PGID environment variables for privilege dropping.
      ] ++ lib.optionals cfg.healthcheck.enable [
        # Define the health check on the container itself.
        # This allows `podman healthcheck run` to work and updates status in `podman ps`.
        # NOTE: Dispatcharr container doesn't include curl/wget by default, so we use a TCP connection test
        # to verify nginx (port 9191) is responding. This is less precise than HTTP checks but more reliable.
        ''--health-cmd=sh -c 'timeout 3 bash -c "</dev/tcp/127.0.0.1/9191" 2>/dev/null' ''
        # CRITICAL: Disable Podman's internal timer to prevent transient systemd units.
        # Use "0s" instead of "disable" for better Podman version compatibility
        "--health-interval=0s"
        "--health-timeout=${cfg.healthcheck.timeout}"
        "--health-retries=${toString cfg.healthcheck.retries}"
        "--health-start-period=${cfg.healthcheck.startPeriod}"
      ];
    };

    # Add systemd dependencies and notifications
    systemd.services."${config.virtualisation.oci-containers.backend}-dispatcharr" = lib.mkMerge [
      # Add failure notifications via systemd
      (lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
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
        requires = [ "postgresql-provision-databases.service" ];
        after = [ "postgresql.service" "postgresql-provision-databases.service" ];

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

    # Create explicit health check timer/service that we control
    # We don't use Podman's native --health-* flags because they create transient units
    # that bypass systemd overrides and cause activation failures
    systemd.timers.dispatcharr-healthcheck = lib.mkIf cfg.healthcheck.enable {
      description = "Dispatcharr Container Health Check Timer";
      wantedBy = [ "timers.target" ];
      after = [ mainServiceUnit ];
      timerConfig = {
        # Delay first check to allow container initialization
        OnActiveSec = cfg.healthcheck.startPeriod;  # e.g., "300s"
        # Regular interval for subsequent checks
        OnUnitActiveSec = cfg.healthcheck.interval;  # e.g., "30s"
        # Continue timer even if check fails
        Persistent = false;
      };
    };

    systemd.services.dispatcharr-healthcheck = lib.mkIf cfg.healthcheck.enable {
      description = "Dispatcharr Container Health Check";
      after = [ mainServiceUnit ];
      serviceConfig = {
        Type = "oneshot";
        # We allow the unit to fail for better observability. The timer's OnActiveSec
        # provides the startup grace period, and after that we want genuine failures
        # to be visible in systemctl --failed for monitoring.
        ExecStart = pkgs.writeShellScript "dispatcharr-healthcheck" ''
          set -euo pipefail

          # 1. Check if container is running to avoid unnecessary errors
          if ! ${pkgs.podman}/bin/podman inspect dispatcharr --format '{{.State.Running}}' | grep -q true; then
            echo "Container dispatcharr is not running, skipping health check."
            exit 1
          fi

          # 2. Run the health check defined in the container.
          # This updates the container's status for `podman ps` and exits with
          # a proper status code for systemd.
          if ${pkgs.podman}/bin/podman healthcheck run dispatcharr; then
            echo "Health check passed."
            exit 0
          else
            echo "Health check failed."
            exit 1
          fi
        '';
      };
    };

    # Register notification template
    modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
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

    # Integrate with backup system
    # Reuses existing backup infrastructure (Restic, notifications, etc.)
    modules.backup.restic.jobs.dispatcharr = lib.mkIf (config.modules.backup.enable && cfg.backup.enable) {
      enable = true;
      paths = [ cfg.dataDir ];
      excludePatterns = [
        "**/.cache"
        "**/cache"
        "**/__pycache__"      # Python bytecode cache
        "**/*.pyc"            # Compiled Python files
        "**/.pytest_cache"    # Pytest cache
        "**/*.tmp"
        "**/logs/*.txt"       # Exclude verbose logs
        "**/logs/*.log"
        "**/db/pg_log/*"      # PostgreSQL logs (if stored in data dir)
      ];
      repository = cfg.backup.repository;
      tags = [ "dispatcharr" "iptv" "database" "postgresql" ];
    };

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
        replicationCfg = replicationConfig;  # Pass the auto-discovered replication config
        datasetProperties = {
          recordsize = "8K";     # Optimal for PostgreSQL databases
          compression = "lz4";   # Fast compression suitable for database workloads
          "com.sun:auto-snapshot" = "true";  # Enable sanoid snapshots for this dataset
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
