{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Import storage helpers for preseed integration
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  # Import scripts library
  scriptsLib = import ./scripts.nix { inherit lib pkgs; };

  # Generate configuration for each PostgreSQL instance
  mkInstanceConfig = instanceName: instanceCfg:
    let
      # Replication discovery helper (moved inside function to avoid circular dependency)
      # This allows a service dataset to inherit replication config from a parent dataset
      findReplication = dsPath:
        if dsPath == "" || dsPath == "." then null
        else
          let
            sanoidDatasets = config.modules.backup.sanoid.datasets;
            replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
            parentPath =
              if lib.elem "/" (lib.stringToCharacters dsPath) then
                lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
              else
                "";
          in
          if replicationInfo != null then
            { sourcePath = dsPath; replication = replicationInfo; }
          else
            findReplication parentPath;

      dataDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}";
      walArchiveDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}-wal-archive";
      walIncomingDir = "${walArchiveDir}/incoming";

      pgPackage = pkgs."postgresql_${builtins.replaceStrings ["."] [""] instanceCfg.version}";

      # Check if centralized notifications are enabled (inline to avoid circular dependency)
      hasCentralizedNotifications = config.modules.notifications.enable or false;

      # Metrics directory for node_exporter - use consistent path from monitoring module
      metricsDir = config.modules.monitoring.nodeExporter.textfileCollector.directory or "/var/lib/node_exporter/textfile_collector";

      # Compute dataset path and replication config (FIX: CRITICAL #1 - Preseed integration)
      storageCfg = config.modules.storage;
      datasetPath = "${storageCfg.datasets.parentDataset}/postgresql/${instanceName}";
      foundReplication = findReplication datasetPath;
      replicationConfig =
        if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then null
        else
          let
            datasetSuffix = lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
          in {
            targetHost = foundReplication.replication.targetHost;
            targetDataset =
              if datasetSuffix == ""
              then foundReplication.replication.targetDataset
              else "${foundReplication.replication.targetDataset}/${datasetSuffix}";
            sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
            sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
            sendOptions = foundReplication.replication.sendOptions or "w";
            recvOptions = foundReplication.replication.recvOptions or "u";
          };

      # Import shell scripts from scripts.nix
      scripts = scriptsLib.mkScripts {
        inherit instanceName instanceCfg dataDir walArchiveDir walIncomingDir pgPackage metricsDir;
      };

      # Common systemd hardening (FIX: MEDIUM #3)
      hardeningCommon = {
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };

      # Main PostgreSQL service unit name (used by backup/health services)
      mainServiceUnit = "postgresql.service";

      # NOTE: Shell scripts (walArchiveScript, walRestoreScript, baseBackupScript, healthCheckScript)
      # are now defined in scripts.nix and imported via scripts = scriptsLib.mkScripts { ... }
    in
    {
      # Wire datasets to storage.datasets.services (not a local unused attrset)
      modules.storage.datasets.services = {
        # Data dataset with PostgreSQL-optimal settings
        "postgresql/${instanceName}" = {
          mountpoint = dataDir;
          recordsize = "8K";  # PostgreSQL page size
          compression = "lz4";
          properties = {
            atime = "off";
            xattr = "sa";
            dnodesize = "auto";
          };
          owner = "postgres";
          group = "postgres";
          mode = "0700";
        };

        # WAL archive dataset with sequential write optimization
        "postgresql/${instanceName}-wal" = {
          mountpoint = walArchiveDir;
          recordsize = "128K";  # Sequential writes
          compression = "lz4";
          properties = {
            atime = "off";
            logbias = "throughput";  # Optimize for throughput over latency
            sync = "standard";  # Balance safety and performance
          };
          owner = "postgres";
          group = "postgres";
          mode = "0700";
        };
      };

      # Wire PostgreSQL service to NixOS services.postgresql (single instance only)
      # NOTE: NixOS only supports one PostgreSQL instance via services.postgresql
      # For multi-instance, we would need custom systemd units (future enhancement)
      services.postgresql = {
        enable = true;
        package = pgPackage;
        dataDir = dataDir;

        # Ensure datasets are mounted before PostgreSQL starts
        # FIX: MEDIUM #1 - Use RequiresMountsFor instead of After for proper ordering
        serviceConfig = {
          RequiresMountsFor = [ dataDir walArchiveDir ];
          After = [ "zfs-mount.service" ];
        } // lib.optionalAttrs instanceCfg.preseed.enable {
          Wants = [ "preseed-postgresql-${instanceName}.service" ];
          After = [ "preseed-postgresql-${instanceName}.service" ];
        };

        # Recovery mode configuration - Create recovery.signal for PITR
        # FIX: Moved from postStart to preStart so recovery takes effect on this boot
        preStart = lib.mkIf instanceCfg.recovery.enable ''
          if [ ! -f ${dataDir}/recovery.signal ]; then
            touch ${dataDir}/recovery.signal
            chown postgres:postgres ${dataDir}/recovery.signal
            chmod 0600 ${dataDir}/recovery.signal
          fi
        '';

        # Clean up recovery.signal on shutdown to prevent accidental recovery mode on restart
        preStop = lib.mkIf instanceCfg.recovery.enable ''
          rm -f ${dataDir}/recovery.signal
        '';

        # PostgreSQL configuration
        settings = {
          # Connection settings
          port = instanceCfg.port;
          listen_addresses = instanceCfg.listenAddresses;
          max_connections = instanceCfg.maxConnections;

          # Memory settings (tuned for workload)
          shared_buffers = instanceCfg.sharedBuffers;
          effective_cache_size = instanceCfg.effectiveCacheSize;
          work_mem = instanceCfg.workMem;
          maintenance_work_mem = instanceCfg.maintenanceWorkMem;

          # WAL settings for PITR
          wal_level = "replica";  # Required for PITR
          archive_mode = if instanceCfg.backup.walArchive.enable then "on" else "off";
          archive_command = if instanceCfg.backup.walArchive.enable
            then "${scripts.walArchiveScript} %p %f"
            else "";
          archive_timeout = instanceCfg.backup.walArchive.archiveTimeout;

          # Checkpoint settings
          checkpoint_timeout = "15min";
          max_wal_size = "2GB";
          min_wal_size = "512MB";

          # Query tuning
          random_page_cost = 1.1;  # For SSD/ZFS
          effective_io_concurrency = 200;

          # Logging
          log_destination = "stderr";
          logging_collector = true;
          log_directory = "log";
          log_filename = "postgresql-%Y-%m-%d_%H%M%S.log";
          log_rotation_age = "1d";
          log_rotation_size = "100MB";
          log_line_prefix = "%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h ";
          log_timezone = "UTC";

          # Monitoring
          track_activities = true;
          track_counts = true;
          track_io_timing = true;
          track_wal_io_timing = lib.mkIf (lib.versionAtLeast instanceCfg.version "14") true;
        } // lib.optionalAttrs instanceCfg.recovery.enable {
          # Restore settings for PITR recovery mode
          restore_command = "${scripts.walRestoreScript} %f %p";
          recovery_target_action = "promote";
        } // lib.optionalAttrs (instanceCfg.recovery.enable && instanceCfg.recovery.target != "immediate") {
          # Recovery target settings
          recovery_target_time = instanceCfg.recovery.targetTime or "";
          recovery_target_xid = instanceCfg.recovery.targetXid or "";
          recovery_target_name = instanceCfg.recovery.targetName or "";
        } // instanceCfg.extraSettings;

        # Initialize databases
        initialScript = lib.mkIf (instanceCfg.databases != []) (pkgs.writeText "init-${instanceName}.sql" ''
          ${lib.concatMapStringsSep "\n" (db: ''
            SELECT 'CREATE DATABASE ${db}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec
          '') instanceCfg.databases}
        '');
      };

      # Base backup timer and service
      systemd.timers."postgresql-basebackup-${instanceName}" = lib.mkIf instanceCfg.backup.baseBackup.enable {
        description = "PostgreSQL base backup timer for ${instanceName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = instanceCfg.backup.baseBackup.schedule;
          Persistent = true;
          RandomizedDelaySec = "30min";
        };
      };

      systemd.services."postgresql-basebackup-${instanceName}" = lib.mkIf instanceCfg.backup.baseBackup.enable {
        description = "PostgreSQL base backup for ${instanceName}";
        after = [ mainServiceUnit ];
        requires = [ mainServiceUnit ];

        # FIX: MEDIUM #3 - Apply systemd hardening
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          ExecStart = "${scripts.baseBackupScript}";
        } // hardeningCommon // {
          ReadWritePaths = [ dataDir "/var/backup/postgresql/${instanceName}" ];
        } // lib.optionalAttrs (config.modules.monitoring.enable or false) {
          SupplementaryGroups = [ "node-exporter" ];
        };

        unitConfig = lib.mkIf (config.modules.notifications.enable or false) {
          OnFailure = [ "notify@postgresql-backup-failure:${instanceName}.service" ];
        };
      };

      # NOTE: WAL sync timer and service removed - now using modules.backup.restic.jobs (FIX: CRITICAL #2)
      # The Restic backup jobs are registered below in the modules.backup.restic.jobs section
      # The WAL sync schedule is controlled by the timerConfig in the Restic job definition

      # Health check service
      systemd.services."postgresql-healthcheck-${instanceName}" = lib.mkIf instanceCfg.healthCheck.enable {
        description = "PostgreSQL health check for ${instanceName}";
        after = [ mainServiceUnit ];

        # FIX: MEDIUM #3 - Apply systemd hardening
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          ExecStart = "${scripts.healthCheckScript}";
        } // hardeningCommon // {
          ReadWritePaths = lib.optional (config.modules.monitoring.enable or false)
            (config.modules.monitoring.prometheus.metricsDir or "/var/lib/node_exporter/textfile_collector");
        } // lib.optionalAttrs (config.modules.monitoring.enable or false) {
          SupplementaryGroups = [ "node-exporter" ];
        };

        unitConfig = lib.mkIf (config.modules.notifications.enable or false) {
          OnFailure = [ "notify@postgresql-health-failure:${instanceName}.service" ];
        };
      };

      systemd.timers."postgresql-healthcheck-${instanceName}" = lib.mkIf instanceCfg.healthCheck.enable {
        description = "PostgreSQL health check timer for ${instanceName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = instanceCfg.healthCheck.interval;
        };
      };

      # WAL archive pruning service (FIX: HIGH #3)
      systemd.services."postgresql-walprune-${instanceName}" = lib.mkIf instanceCfg.backup.walArchive.enable {
        description = "PostgreSQL WAL archive pruning for ${instanceName}";
        after = [ mainServiceUnit ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          ExecStart = pkgs.writeShellScript "pg-walprune-${instanceName}" ''
            set -euo pipefail

            echo "Pruning WAL archives older than ${toString instanceCfg.backup.walArchive.retentionDays} days for ${instanceName}"

            # Find and delete WAL files older than retention period
            ${pkgs.findutils}/bin/find "${walArchiveDir}" \
              -type f \
              \( -name "*.gz" -o -name "*.zst" -o -name "0*" \) \
              -mtime +${toString instanceCfg.backup.walArchive.retentionDays} \
              -delete

            # Find and delete old archive logs
            ${pkgs.findutils}/bin/find "${walArchiveDir}" \
              -type f \
              -name "*.log" \
              -mtime +${toString instanceCfg.backup.walArchive.retentionDays} \
              -delete

            echo "WAL pruning completed for ${instanceName}"
          '';
        } // hardeningCommon // {
          ReadWritePaths = [ walArchiveDir ];
        };
      };

      systemd.timers."postgresql-walprune-${instanceName}" = lib.mkIf instanceCfg.backup.walArchive.enable {
        description = "PostgreSQL WAL archive pruning timer for ${instanceName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    }

    # Add preseed service (FIX: CRITICAL #1)
    // lib.optionalAttrs instanceCfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "postgresql-${instanceName}";
        dataset = datasetPath;
        mountpoint = dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;  # Auto-discovered from parent dataset
        datasetProperties = {
          recordsize = "8K";  # PostgreSQL page size
          compression = "lz4";
          "com.sun:auto-snapshot" = "true";  # Enable sanoid snapshots
        };
        resticRepoUrl = instanceCfg.preseed.repositoryUrl or instanceCfg.backup.restic.repositoryUrl;
        resticPasswordFile = instanceCfg.preseed.passwordFile or instanceCfg.backup.restic.passwordFile;
        resticEnvironmentFile = instanceCfg.preseed.environmentFile or instanceCfg.backup.restic.environmentFile;
        resticPaths = [ dataDir ];
        restoreMethods = instanceCfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "postgres";
        group = "postgres";
        # Note: PostgreSQL-specific options (postgresqlVersion, asStandby, clearReplicationSlots,
        # pitrTarget, pitrTargetValue) removed until mkPreseedService is extended to support them
      }
    )

    # Add Restic backup jobs (FIX: CRITICAL #2 - Replace custom WAL sync service)
    // lib.optionalAttrs (instanceCfg.backup.restic.enable && config.modules.backup.enable or false) {
      modules.backup.restic.jobs = {
        # WAL archive backup job
        "postgresql-${instanceName}-wal" = {
          enable = true;
          paths = [ walArchiveDir ];
          excludePatterns = [
            "**/*.tmp"
            "**/incoming/*.tmp"  # Exclude temporary incoming files
          ];
          repository = instanceCfg.backup.restic.repositoryName;
          tags = [ "postgresql" instanceName "wal-archive" "pitr" ];
          # WAL archives are small and frequent - back up more often
          timerConfig = {
            OnCalendar = instanceCfg.backup.walArchive.syncInterval;
            Persistent = true;
          };
        };

        # Base backup job (full data directory)
        "postgresql-${instanceName}-base" = {
          enable = true;
          paths = [ "/var/backup/postgresql/${instanceName}" ];
          excludePatterns = [
            "**/postmaster.pid"    # Exclude PID file
            "**/postmaster.opts"   # Exclude runtime options
            "**/*.tmp"
            "**/pg_log/*"          # Exclude logs
            "**/pg_xlog/*"         # Old PostgreSQL (< 10) WAL location
            "**/pg_wal/*"          # New PostgreSQL (>= 10) WAL location
          ];
          repository = instanceCfg.backup.restic.repositoryName;
          tags = [ "postgresql" instanceName "base-backup" "pitr" ];
          # Base backups are large - back up daily
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
          };
        };
      };
    };
in
{
  options.modules.services.postgresql = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
      options = {
        enable = lib.mkEnableOption "PostgreSQL instance";

        version = lib.mkOption {
          type = lib.types.enum [ "14" "15" "16" ];
          default = "16";
          description = "PostgreSQL major version";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 5432;
          description = "PostgreSQL port";
        };

        listenAddresses = lib.mkOption {
          type = lib.types.str;
          default = "localhost";
          description = "Addresses to listen on (comma-separated)";
        };

        maxConnections = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "Maximum number of concurrent connections";
        };

        # Memory tuning
        sharedBuffers = lib.mkOption {
          type = lib.types.str;
          default = "256MB";
          description = "Amount of memory for shared buffers";
        };

        effectiveCacheSize = lib.mkOption {
          type = lib.types.str;
          default = "1GB";
          description = "Planner's assumption of effective cache size";
        };

        workMem = lib.mkOption {
          type = lib.types.str;
          default = "4MB";
          description = "Memory for internal sort operations and hash tables";
        };

        maintenanceWorkMem = lib.mkOption {
          type = lib.types.str;
          default = "64MB";
          description = "Memory for maintenance operations";
        };

        # Database initialization
        databases = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "List of databases to create on initialization";
          example = [ "app1" "app2" ];
        };

        # WAL archiving configuration
        backup.walArchive = {
          enable = lib.mkEnableOption "WAL archiving" // { default = true; };

          archiveTimeout = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Force WAL switch after this many seconds (bounds RPO)";
          };

          syncInterval = lib.mkOption {
            type = lib.types.str;
            default = "*/5";
            description = "How often to sync WAL archive to off-site storage (systemd OnCalendar format, e.g., '*/5' for every 5 minutes)";
          };

          retentionDays = lib.mkOption {
            type = lib.types.int;
            default = 30;
            description = "How long to retain WAL archives (days)";
          };
        };

        # Base backup configuration
        backup.baseBackup = {
          enable = lib.mkEnableOption "base backups" // { default = true; };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            description = "Backup schedule (systemd timer format)";
          };

          retention = lib.mkOption {
            type = lib.types.submodule {
              options = {
                daily = lib.mkOption { type = lib.types.int; default = 7; };
                weekly = lib.mkOption { type = lib.types.int; default = 4; };
                monthly = lib.mkOption { type = lib.types.int; default = 3; };
              };
            };
            default = {};
            description = "Backup retention policy";
          };
        };

        # Restic integration
        backup.restic = {
          enable = lib.mkEnableOption "Restic backups" // { default = true; };

          repositoryName = lib.mkOption {
            type = lib.types.str;
            description = "Name of a configured Restic repository (e.g., 'nas-primary')";
          };

          repositoryUrl = lib.mkOption {
            type = lib.types.str;
            description = "Restic repository URL (for preseed restore_command)";
          };

          passwordFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to Restic password file";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to environment file for Restic (S3 credentials, etc.)";
          };
        };

        # Preseed configuration (automatic first-boot restoration)
        preseed = {
          enable = lib.mkEnableOption "preseed (automatic first-boot restoration)" // { default = false; };

          restoreMethods = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" "restic" ];
            description = ''
              Ordered list of restore methods to try on first boot.
              - syncoid: Fast full data directory restore from remote ZFS snapshot via syncoid
              - local: Restore from local ZFS snapshot (if available)
              - restic: PITR bootstrap from Restic (restore base backup + replay WAL)
            '';
          };

          asStandby = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Keep standby.signal after restore to start as a standby server.
              If false (default), recovery.signal and standby.signal are removed after restore.
            '';
          };

          clearReplicationSlots = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Clear replication slots after restore to avoid WAL pinning on newly promoted primaries.
              Disable only if explicitly restoring as a standby with existing slots.
            '';
          };

          pitr = {
            target = lib.mkOption {
              type = lib.types.enum [ "latest" "time" "xid" "name" ];
              default = "latest";
              description = "PITR target type for pitr-restic restore method";
            };

            targetValue = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "PITR target value (timestamp for 'time', xid for 'xid', name for 'name')";
              example = "2025-10-10 12:00:00";
            };
          };

          repositoryUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Restic repository URL (defaults to backup.restic.repositoryUrl)";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Restic password file (defaults to backup.restic.passwordFile)";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Restic environment file (defaults to backup.restic.environmentFile)";
          };
        };

        # Recovery configuration (PITR)
        recovery = {
          enable = lib.mkEnableOption "recovery mode (PITR)";

          target = lib.mkOption {
            type = lib.types.enum [ "immediate" "time" "xid" "name" ];
            default = "immediate";
            description = "Recovery target type";
          };

          targetTime = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target timestamp (ISO 8601 format)";
            example = "2025-10-10 12:00:00";
          };

          targetXid = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target transaction ID";
          };

          targetName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Recovery target restore point name";
          };
        };

        # Health checks
        healthCheck = {
          enable = lib.mkEnableOption "health checks" // { default = true; };

          interval = lib.mkOption {
            type = lib.types.str;
            default = "1min";
            description = "Health check interval";
          };

          checkReplicationLag = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Check replication lag (for standby servers)";
          };

          maxReplicationLagSeconds = lib.mkOption {
            type = lib.types.int;
            default = 300;
            description = "Maximum acceptable replication lag in seconds";
          };
        };

        # Extra PostgreSQL settings
        extraSettings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Additional PostgreSQL configuration settings";
        };
      };

      # NOTE: Submodule config can't set top-level options like services.postgresql
      # Configuration is generated at parent module level instead
    }));
    default = {};
    description = "PostgreSQL instances with PITR support";
  };

  config = lib.mkMerge [
    # Assertions
    {
      # NOTE: Single-instance limitation documented in module description
      # Assertion removed to avoid circular dependency (would need to read config.modules.services.postgresql)
      # User should only enable one instance due to NixOS services.postgresql constraints
    }

    # NOTE: Config generation moved to implementation.nix (separate module)
    # This avoids circular dependency by splitting options and config into separate modules
    {}

    # Notification templates
    (lib.mkIf (config.modules.notifications.enable or false) {
      modules.notifications.templates = {
        postgresql-backup-success = {
          enable = true;
          priority = "normal";
          title = "✅ PostgreSQL Backup Complete";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Backup Path:</b> ''${backuppath}
            <b>Status:</b> Success
          '';
        };

        postgresql-backup-failure = {
          enable = true;
          priority = "high";
          title = "✗ PostgreSQL Backup Failed";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check backup logs
          '';
        };

        postgresql-health-failure = {
          enable = true;
          priority = "high";
          title = "⚠ PostgreSQL Health Check Failed";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Error:</b> ''${errormessage}
            <b>Action Required:</b> Check PostgreSQL service status
          '';
        };

        postgresql-replication-lag = {
          enable = true;
          priority = "normal";  # Changed from "medium" (not a valid priority)
          title = "⚠ PostgreSQL Replication Lag";
          body = ''
            <b>Instance:</b> ''${instance}
            <b>Lag:</b> ''${lag} seconds
            <b>Status:</b> Replication is falling behind
          '';
        };
      };
    })
  ];

  # FIXME: Database provisioning module creates circular dependency
  # databases.nix tries to read config.modules.services.postgresql.databases
  # which is part of the same config tree this module defines
  # Need to restructure database provisioning to avoid this circular reference
  # imports = [ ./databases.nix ];
}
