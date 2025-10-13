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

          # Automatic restore from backup on server rebuild (disaster recovery)
          # This enables automatic PostgreSQL restore when PGDATA is empty (e.g., fresh install, hardware migration)
          # See docs/postgresql-auto-restore-homelab.md for details
          preSeed = {
            enable = true;
            source = {
              stanza = "main";
              repository = 1;  # Use repo1 (NFS) - faster, has WALs, local network
              backupSet = "latest";
            };
            # Optional: Switch to R2 if NAS is unavailable
            # source.repository = 2;
          };      # Memory settings (tune based on available RAM)
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
        # The archive_command uses the global config (/etc/pgbackrest.conf), which only defines repo1.
        # Therefore, WALs are archived only to the primary NFS repo.
        # Backup jobs separately push to repo2 (R2) using command-line flags with --no-archive-check.
        archive_command = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=main archive-push %p";
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

    # Override PostgreSQL systemd service to allow writes to NFS mount and local spool for pgBackRest
    systemd.services.postgresql.serviceConfig = {
      # Add paths to ReadWritePaths to allow archive_command to write WAL segments
      # Without these, ProtectSystem=strict blocks writes outside /var/lib/postgresql
      # 1. /mnt/nas-backup: NFS repo1 (used by pgBackRest background process)
      # 2. /var/lib/pgbackrest/spool: Local async spool (archive_command writes here first)
      ReadWritePaths = [
        "/mnt/nas-backup"
        "/var/lib/pgbackrest/spool"
      ];
    };
  };
}
