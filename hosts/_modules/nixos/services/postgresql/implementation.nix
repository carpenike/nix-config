{ lib, pkgs, config, ... }:
# PostgreSQL Implementation Module (Minimal - Service Generation Only)
#
# This module ONLY generates services.postgresql configuration.
# It does NOT handle storage datasets or backup jobs (those are in integration modules).
#
# Architecture (one-way dependencies only):
# - Reads: config.modules.services.postgresql (instance definitions)
# - Writes: services.postgresql + postgresql-* systemd units ONLY
# - Does NOT read: config.modules.backup.*, config.modules.storage.*
# - Does NOT write: modules.storage.*, modules.backup.*
{
  config =
    let
      # LAZY EVALUATION: Read instances inside config block
      instances = config.modules.services.postgresql or {};
      enabledInstances = lib.filterAttrs (name: cfg: cfg.enable) instances;
      hasInstance = enabledInstances != {};

      # NixOS services.postgresql only supports ONE instance
      mainInstanceName = if hasInstance then (lib.head (lib.attrNames enabledInstances)) else "";
      mainInstance = if hasInstance then enabledInstances.${mainInstanceName} else {};

      # Paths
      dataDir = if hasInstance then "/var/lib/postgresql/${mainInstance.version}/${mainInstanceName}" else "";
      walArchiveDir = if hasInstance then "/var/lib/postgresql/${mainInstance.version}/${mainInstanceName}-wal-archive" else "";
      pgPackage = if hasInstance then pkgs.${"postgresql_${lib.replaceStrings ["."] [""] mainInstance.version}"} else null;
    in
    lib.mkIf hasInstance {
      # Enable the base PostgreSQL service
      services.postgresql = {
        enable = true;
        package = pgPackage;
        dataDir = dataDir;

        # Basic configuration
        settings = lib.mkMerge [
          {
            port = mainInstance.port;
            listen_addresses = lib.mkDefault mainInstance.listenAddresses;
            max_connections = lib.mkDefault mainInstance.maxConnections;

            # Memory settings
            shared_buffers = lib.mkDefault mainInstance.sharedBuffers;
            effective_cache_size = lib.mkDefault mainInstance.effectiveCacheSize;
            work_mem = lib.mkDefault mainInstance.workMem;
            maintenance_work_mem = lib.mkDefault mainInstance.maintenanceWorkMem;

            # Logging
            log_destination = lib.mkDefault "stderr";
            logging_collector = lib.mkDefault true;
            log_directory = lib.mkDefault "log";
            log_filename = lib.mkDefault "postgresql-%Y-%m-%d_%H%M%S.log";
            log_rotation_age = lib.mkDefault "1d";
            log_rotation_size = lib.mkDefault "100MB";
            log_line_prefix = lib.mkDefault "%m [%p] %u@%d ";
            log_timezone = lib.mkDefault "UTC";
          }

          # WAL archiving for Point-in-Time Recovery (PITR)
          # Only enabled when backup.walArchive.enable is true
          (lib.mkIf (mainInstance.backup.walArchive.enable or false) {
            # Enable WAL archiving
            archive_mode = "on";

            # Compress WAL files to reduce storage and I/O overhead
            # Typically achieves 50-80% compression ratio
            wal_compression = "on";

            # Archive command uses atomic write pattern (cp to temp, then mv)
            # This prevents corrupted archives from interrupted transfers
            # PostgreSQL will retry automatically if the command fails
            archive_command = "test ! -f ${walArchiveDir}/%f && cp %p ${walArchiveDir}/.tmp.%f && mv ${walArchiveDir}/.tmp.%f ${walArchiveDir}/%f";

            # Archive timeout - force WAL segment switch after this interval
            # Ensures regular archiving even during low write activity
            archive_timeout = toString mainInstance.backup.walArchive.archiveTimeout; # Default: 300 seconds (5 minutes)
          })

          # Merge in user's extra settings (can override defaults)
          mainInstance.extraSettings
        ];

        # Enable authentication
        # peer = Unix user must match database role (secure for local admin)
        # scram-sha-256 = Password required over TCP/IP
        authentication = lib.mkDefault ''
          local all postgres peer
          local all all peer
          host all all 127.0.0.1/32 scram-sha-256
          host all all ::1/128 scram-sha-256
        '';
      };

      # Extend systemd service configuration
      systemd.services.postgresql = {
        # Ensure PostgreSQL doesn't start until required directories are mounted
        # This is critical for ZFS datasets
        unitConfig = {
          RequiresMountsFor = [ dataDir ] ++ lib.optional (mainInstance.backup.walArchive.enable or false) walArchiveDir;
        };

        # Ensure ZFS mounts are complete before starting
        after = [ "zfs-mount.service" ];

        # Allow write access to WAL archive directory when PITR is enabled
        # Note: Using lib.optionals for list construction is cleaner than mkIf for this pattern
        serviceConfig.ReadWritePaths = lib.optionals (mainInstance.backup.walArchive.enable or false) [ walArchiveDir ];
      };

      # Assertion to ensure only one instance
      assertions = [{
        assertion = (lib.length (lib.attrNames enabledInstances)) == 1;
        message = "Only one PostgreSQL instance is currently supported due to NixOS services.postgresql limitations. Found: ${lib.concatStringsSep ", " (lib.attrNames enabledInstances)}";
      }];
    };
}
