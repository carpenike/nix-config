{ config, ... }:
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
# - Backup integration via restic
# - Health monitoring and notifications
#
# Secret paths are passed via postgresSecrets parameter (defined in forge/default.nix)
# to avoid circular dependencies in module evaluation
{
  config = {
    # Enable PostgreSQL service
    modules.services.postgresql = {
      # Main PostgreSQL instance (no .instances wrapper needed)
      main = {
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
          # WAL settings for better durability and performance
          wal_level = "replica";  # Enable for potential future replication
          max_wal_size = "2GB";
          min_wal_size = "512MB";

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

        # Enable backup via restic
        backup = {
          enable = true;
          repository = "nas-primary";
          schedule = "daily";  # Base backups daily at 01:00
        };

        # Enable health monitoring
        healthCheck.enable = true;

        # Enable notifications
        notifications.enable = true;

        # Enable preseed for disaster recovery
        preseed = {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
        };
      };

      # Declarative database provisioning
      databases = {
        dispatcharr = {
          owner = "dispatcharr";
          ownerPasswordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
          extensions = [ "uuid-ossp" ];
          permissionsPolicy = "owner-readwrite+readonly-select";
        };
      };
    };
  };
}
