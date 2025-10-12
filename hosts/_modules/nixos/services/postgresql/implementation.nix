{
  lib,
  pkgs,
  config,
  ...
}:
# PostgreSQL Implementation Module
#
# This module contains the config generation logic for PostgreSQL instances.
# It's separated from default.nix to avoid circular dependencies:
# - default.nix defines options.modules.services.postgresql
# - implementation.nix reads config.modules.services.postgresql and generates config
#
# This split allows the NixOS module system to properly evaluate both without recursion.
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
            parentPath = builtins.dirOf dsPath;
            datasets = config.modules.backup.sanoid.datasets or {};
          in
            if datasets ? ${dsPath} && datasets.${dsPath}.syncoid.enable or false then
              datasets.${dsPath}.syncoid
            else if parentPath != dsPath then
              findReplication parentPath
            else
              null;

      pgPackage = pkgs.${"postgresql_${instanceCfg.version}"};
      dataDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}";
      walArchiveDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}-wal-archive";

      # Restic repository configuration (with preseed fallbacks)
      resticRepo = instanceCfg.backup.restic.repositoryUrl;
      resticPasswordFile = instanceCfg.backup.restic.passwordFile;
      resticEnvFile = instanceCfg.backup.restic.environmentFile;

      # Preseed configuration (for first-boot restore)
      preseedRepo = if instanceCfg.preseed.repositoryUrl != null
                    then instanceCfg.preseed.repositoryUrl
                    else resticRepo;
      preseedPasswordFile = if instanceCfg.preseed.passwordFile != null
                           then instanceCfg.preseed.passwordFile
                           else resticPasswordFile;
      preseedEnvFile = if instanceCfg.preseed.environmentFile != null
                       then instanceCfg.preseed.environmentFile
                       else resticEnvFile;

      # Determine if this dataset has replication configured
      datasetPath = "tank/services/postgresql-${instanceName}";
      replicationConfig = findReplication datasetPath;

      # Scripts for backup and restore operations
      walArchiveScript = scriptsLib.mkWalArchiveScript {
        inherit instanceName dataDir walArchiveDir resticRepo resticPasswordFile resticEnvFile;
      };

      walRestoreScript = scriptsLib.mkWalRestoreScript {
        inherit instanceName dataDir resticRepo resticPasswordFile resticEnvFile;
      };

      baseBackupScript = scriptsLib.mkBaseBackupScript {
        inherit instanceName dataDir walArchiveDir pgPackage;
        retention = instanceCfg.backup.baseBackup.retention;
      };

      preseedScript = scriptsLib.mkPreseedScript {
        inherit instanceName dataDir walArchiveDir pgPackage;
        inherit preseedRepo preseedPasswordFile preseedEnvFile;
        restoreMethods = instanceCfg.preseed.restoreMethods;
        asStandby = instanceCfg.preseed.asStandby;
        clearReplicationSlots = instanceCfg.preseed.clearReplicationSlots;
        pitrTarget = instanceCfg.preseed.pitr.target;
        pitrTargetValue = instanceCfg.preseed.pitr.targetValue;
        replicationConfig = replicationConfig;
      };

      healthCheckScript = scriptsLib.mkHealthCheckScript {
        inherit instanceName dataDir pgPackage;
        checkReplicationLag = instanceCfg.healthCheck.checkReplicationLag;
        maxReplicationLagSeconds = instanceCfg.healthCheck.maxReplicationLagSeconds;
      };

      walPruneScript = scriptsLib.mkWalPruneScript {
        inherit instanceName walArchiveDir;
        retentionDays = instanceCfg.backup.walArchive.retentionDays;
      };

      # PostgreSQL configuration
      postgresqlSettings = {
        # Connection settings
        listen_addresses = instanceCfg.listenAddresses;
        port = instanceCfg.port;
        max_connections = instanceCfg.maxConnections;

        # Memory settings
        shared_buffers = instanceCfg.sharedBuffers;
        effective_cache_size = instanceCfg.effectiveCacheSize;
        work_mem = instanceCfg.workMem;
        maintenance_work_mem = instanceCfg.maintenanceWorkMem;

        # WAL settings for PITR
        wal_level = "replica";  # Required for PITR
        archive_mode = if instanceCfg.backup.walArchive.enable then "on" else "off";
        archive_command = if instanceCfg.backup.walArchive.enable
                          then "${walArchiveScript} %p %f"
                          else "";
        archive_timeout = if instanceCfg.backup.walArchive.enable
                          then instanceCfg.backup.walArchive.archiveTimeout
                          else 0;

        # Recovery settings (PITR restore)
        restore_command = if instanceCfg.preseed.enable || instanceCfg.recovery.enable
                          then "${walRestoreScript} %f %p"
                          else "";
        recovery_target = if instanceCfg.recovery.enable then instanceCfg.recovery.target else null;
        recovery_target_time = instanceCfg.recovery.targetTime;
        recovery_target_xid = instanceCfg.recovery.targetXid;
        recovery_target_name = instanceCfg.recovery.targetName;

        # Logging
        log_destination = "stderr";
        logging_collector = true;
        log_directory = "log";
        log_filename = "postgresql-%Y-%m-%d_%H%M%S.log";
        log_rotation_age = "1d";
        log_rotation_size = "100MB";
        log_line_prefix = "%m [%p] %u@%d ";
        log_timezone = "UTC";

      } // instanceCfg.extraSettings;

    in {
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
        postStop = lib.mkIf instanceCfg.recovery.enable ''
          if [ -f ${dataDir}/recovery.signal ]; then
            rm ${dataDir}/recovery.signal
          fi
        '';

        settings = postgresqlSettings;

        # Initial database creation
        ensureDatabases = instanceCfg.databases;

        # Enable authentication
        authentication = lib.mkDefault ''
          local all all trust
          host all all 127.0.0.1/32 scram-sha-256
          host all all ::1/128 scram-sha-256
        '';
      };

      # ZFS dataset for PostgreSQL data
      # Optimal settings for PostgreSQL: 8K recordsize matches page size, zstd compression
      modules.storage.serviceDatasets."postgresql-${instanceName}" = {
        enable = true;
        path = datasetPath;
        mountpoint = dataDir;
        properties = {
          recordsize = "8K";      # Match PostgreSQL page size
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "false";  # We use pg_basebackup instead
        };
      };

      # WAL archive dataset (separate from data for safety)
      modules.storage.serviceDatasets."postgresql-${instanceName}-wal-archive" = lib.mkIf instanceCfg.backup.walArchive.enable {
        enable = true;
        path = "tank/services/postgresql-${instanceName}-wal-archive";
        mountpoint = walArchiveDir;
        properties = {
          recordsize = "16K";     # WAL files are 16MB, larger recordsize is OK
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";
        };
      };

      # Preseed service (first-boot restoration from backup)
      systemd.services."preseed-postgresql-${instanceName}" = lib.mkIf instanceCfg.preseed.enable {
        description = "PostgreSQL Preseed (${instanceName}) - Restore from backup on first boot";
        wantedBy = [ "multi-user.target" ];
        before = [ "postgresql.service" ];
        after = [ "zfs-mount.service" "network-online.target" ];
        wants = [ "network-online.target" ];

        path = [ pgPackage pkgs.restic pkgs.coreutils pkgs.gawk ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };

        # Preseed only runs if data directory is empty (first boot)
        script = ''
          if [ ! -f ${dataDir}/PG_VERSION ]; then
            echo "PostgreSQL data directory is empty, running preseed..."
            ${preseedScript}
          else
            echo "PostgreSQL data directory exists, skipping preseed"
          fi
        '';
      };

      # Base backup service
      systemd.services."postgresql-basebackup-${instanceName}" = lib.mkIf instanceCfg.backup.baseBackup.enable {
        description = "PostgreSQL Base Backup (${instanceName})";
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];

        path = [ pgPackage pkgs.restic pkgs.coreutils pkgs.gzip ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };

        script = baseBackupScript;
      };

      # Base backup timer
      systemd.timers."postgresql-basebackup-${instanceName}" = lib.mkIf instanceCfg.backup.baseBackup.enable {
        description = "PostgreSQL Base Backup Timer (${instanceName})";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = instanceCfg.backup.baseBackup.schedule;
          Persistent = true;
        };
      };

      # Health check service
      systemd.services."postgresql-healthcheck-${instanceName}" = lib.mkIf instanceCfg.healthCheck.enable {
        description = "PostgreSQL Health Check (${instanceName})";
        after = [ "postgresql.service" ];

        path = [ pgPackage ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };

        script = healthCheckScript;
      };

      # Health check timer
      systemd.timers."postgresql-healthcheck-${instanceName}" = lib.mkIf instanceCfg.healthCheck.enable {
        description = "PostgreSQL Health Check Timer (${instanceName})";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = instanceCfg.healthCheck.interval;
          Persistent = false;
        };
      };

      # WAL archive pruning service (clean up old WAL files)
      systemd.services."postgresql-walprune-${instanceName}" = lib.mkIf instanceCfg.backup.walArchive.enable {
        description = "PostgreSQL WAL Archive Pruning (${instanceName})";

        path = [ pkgs.coreutils pkgs.findutils ];

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };

        script = walPruneScript;
      };

      # WAL pruning timer (daily cleanup)
      systemd.timers."postgresql-walprune-${instanceName}" = lib.mkIf instanceCfg.backup.walArchive.enable {
        description = "PostgreSQL WAL Archive Pruning Timer (${instanceName})";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };

      # Restic integration for PostgreSQL backups
      modules.backup.restic.jobs = lib.mkIf instanceCfg.backup.restic.enable {
        "postgresql-${instanceName}-wal" = {
          enable = true;
          paths = [ walArchiveDir ];
          repository = instanceCfg.backup.restic.repositoryName;
          tags = [ "postgresql" instanceName "wal-archive" "pitr" ];
          # WAL archives are small and frequent - sync every 5 minutes
          timerConfig = {
            OnCalendar = instanceCfg.backup.walArchive.syncInterval;
            Persistent = true;
          };
        };

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
  # This module only contains config, no options
  # Options are defined in default.nix
  config = lib.mkMerge [
    # Apply configuration for each enabled PostgreSQL instance
    (lib.mkMerge (lib.mapAttrsToList (name: instanceCfg:
      lib.mkIf instanceCfg.enable (mkInstanceConfig name instanceCfg)
    ) config.modules.services.postgresql))
  ];
}
