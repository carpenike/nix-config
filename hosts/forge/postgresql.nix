{ config, pkgs, ... }:
# PostgreSQL Configuration for forge
#
# Provides a shared PostgreSQL instance for services on forge that need a database backend.
# Initial use case: dispatcharr (IPTV stream management)
#
# Architecture:
# - Single PostgreSQL 16 instance
# - Databases provisioned declaratively via modules.services.postgresql.databases
# - Automatic role creation with SOPS-managed passwords
# - ZFS dataset with PostgreSQL-optimal settings (8K recordsize)
# - Backup integration via pgBackRest (replaces custom Restic approach)
# - Health monitoring and notifications
#
# Secret paths are passed via postgresSecrets parameter (defined in forge/default.nix)
# to avoid circular dependencies in module evaluation
{
  config = {
    # Enable PostgreSQL service
    modules.services.postgresql = {
      enable = true;
      version = "16";
      port = 5432;

      # Listen only on localhost for security (services connect locally)
      listenAddresses = "localhost";

      # Memory settings (tune based on available RAM)
      sharedBuffers = "256MB";        # 25% of RAM for dedicated DB
      effectiveCacheSize = "1GB";     # ~50% of available RAM
      maintenanceWorkMem = "128MB";
      workMem = "16MB";

      # Additional settings via extraSettings
      extraSettings = {
        # WAL settings for pgBackRest PITR
        wal_level = "replica";  # Required for pgBackRest
        max_wal_size = "2GB";
        min_wal_size = "512MB";
        archive_mode = "on";
        # Archive to repo1 (local NFS) only - repo2 (R2) gets WALs via backup jobs
        # This is the industry-standard pattern: fast local archiving, scheduled remote sync
        archive_command = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=main --repo=1 archive-push %p";
        archive_timeout = "300";  # Force WAL switch every 5 minutes (bounds RPO)

        # Checkpoint settings
        checkpoint_completion_target = "0.9";

        # Query planner (optimized for SSD/NVMe)
        random_page_cost = "1.1";
        effective_io_concurrency = "200";

        # Logging configuration
        log_destination = "stderr";
        logging_collector = true;
        log_directory = "log";
        log_filename = "postgresql-%Y-%m-%d.log";
        log_rotation_age = "1d";
        log_rotation_size = 0;
        log_line_prefix = "%m [%p] %q%u@%d ";
        log_timezone = "UTC";
      };

      # Disable old backup integration (now using pgBackRest directly)
      integration.backup.enable = false;
      backup.walArchive.enable = false;  # Disable module's archive_command (using pgBackRest instead)
      backup.baseBackup.enable = false;  # Disable module's base backup (using pgBackRest instead)

      # Enable health monitoring
      healthCheck.enable = true;

      # Note: Individual databases are declared by their respective service modules
      # See dispatcharr.nix, etc. for database provisioning
      databases = {};
    };
  };
}
