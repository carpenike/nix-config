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
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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
        });

    # Declare dataset requirements for per-service ZFS isolation
    # This integrates with the storage.datasets module to automatically
    # create tank/services/dispatcharr with appropriate ZFS properties
    modules.storage.datasets.services.dispatcharr = {
      mountpoint = cfg.dataDir;
      recordsize = "8K";  # Optimal for PostgreSQL databases (uses embedded postgres)
      compression = "lz4";  # Fast compression suitable for database workloads
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
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
    };

    users.groups.dispatcharr = {
      gid = lib.mkDefault (lib.toInt cfg.group);
    };

    # Dispatcharr container configuration
    virtualisation.oci-containers.containers.dispatcharr = podmanLib.mkContainer "dispatcharr" {
      image = cfg.image;
      environment = {
        PUID = cfg.user;
        PGID = cfg.group;
        TZ = cfg.timezone;
        # Explicitly set All-In-One mode to ensure the container's entrypoint
        # script initializes the embedded Postgres, Redis, and Celery services.
        # This aligns with the official `docker-compose.aio.yml` and makes
        # the deployment more robust against changes in image defaults.
        DISPATCHARR_ENV = "aio";
        CELERY_BROKER_URL = "redis://localhost:6379/0";
        CELERY_RESULT_BACKEND_URL = "redis://localhost:6379/0";
      };
      volumes = [
        "${cfg.dataDir}:/data:rw"
      ];
      ports = [
        "${toString dispatcharrPort}:9191"
      ];
      resources = cfg.resources;
      extraOptions = [
        "--pull=newer"  # Automatically pull newer images
        # Force container to run as the specified user:group
        # This is required for containers that don't process PUID/PGID environment variables
        "--user=${cfg.user}:${cfg.group}"
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
