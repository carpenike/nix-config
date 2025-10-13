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

        # Ensure required filesystems are mounted before PostgreSQL starts
        # This prevents startup failures if ZFS datasets aren't ready
        initialScript = lib.mkAfter ''
          # Systemd will handle mount dependencies via RequiresMountsFor
        '';

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

            # Archive command uses atomic write pattern (cp to temp, then mv)
            # This prevents corrupted archives from interrupted transfers
            # PostgreSQL will retry automatically if the command fails
            archive_command = "test ! -f ${walArchiveDir}/%f && cp %p ${walArchiveDir}/.tmp.%f && mv ${walArchiveDir}/.tmp.%f ${walArchiveDir}/%f";

            # Archive timeout - force WAL segment switch after this interval
            # Ensures regular archiving even during low write activity
            archive_timeout = mainInstance.backup.walArchive.archiveTimeout or "300"; # 5 minutes default
          })

          # Merge in user's extra settings (can override defaults)
          mainInstance.extraSettings
        ];

        # Enable authentication
        authentication = lib.mkDefault ''
          local all all trust
          host all all 127.0.0.1/32 scram-sha-256
          host all all ::1/128 scram-sha-256
        '';
      };

      # Extend systemd service configuration
      systemd.services.postgresql = {
        # Ensure PostgreSQL doesn't start until required directories are mounted
        # This is critical for ZFS datasets
        unitConfig = {
          RequiresMountsFor = lib.mkIf (mainInstance.backup.walArchive.enable or false) [
            dataDir
            walArchiveDir
          ];
        };

        # Ensure ZFS mounts are complete before starting
        after = [ "zfs-mount.service" ];
      };

      # Assertion to ensure only one instance
      assertions = [{
        assertion = (lib.length (lib.attrNames enabledInstances)) == 1;
        message = "Only one PostgreSQL instance is currently supported due to NixOS services.postgresql limitations. Found: ${lib.concatStringsSep ", " (lib.attrNames enabledInstances)}";
      }];
    };
}
