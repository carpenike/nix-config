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
let
  # Secret paths that will be evaluated after config is built
  # This breaks the circular dependency by deferring the path resolution
  resticPasswordPath = config.sops.secrets."restic/password".path;
  dispatcharrPasswordPath = config.sops.secrets."postgresql/dispatcharr_password".path;
in
{
  config = {
    # Enable PostgreSQL service
    modules.services.postgresql = {
      instances = {
        main = {
          enable = true;
          version = "16";
          port = 5432;

          # Listen only on localhost for security (services connect locally)
          listen_addresses = "localhost";

          # Performance tuning (adjust based on available RAM)
          # forge has significant RAM, so we can be generous
          settings = {
            # Memory settings (conservative defaults)
            shared_buffers = "256MB";  # 25% of RAM for a dedicated DB server
            effective_cache_size = "1GB";  # ~50% of available RAM
            maintenance_work_mem = "128MB";
            work_mem = "16MB";

            # WAL settings for better durability and performance
            wal_level = "replica";  # Enable for potential future replication
            max_wal_size = "2GB";
            min_wal_size = "512MB";

            # Checkpoint settings
            checkpoint_completion_target = "0.9";

            # Query planner
            random_page_cost = "1.1";  # Lower for SSD/NVMe
            effective_io_concurrency = "200";  # Higher for NVMe

            # Logging
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
            repository = "nas-primary";  # Direct reference to repository name
            schedule = "daily";  # Base backups daily at 01:00
          };

          # Enable health monitoring
          healthcheck.enable = true;

          # Enable notifications
          notifications.enable = true;

          # Enable preseed for disaster recovery
          preseed = {
            enable = true;
            repositoryUrl = "/mnt/nas-backup";  # Direct reference to avoid circular dependency
            passwordFile = resticPasswordPath;
          };
        };
      };

      # Declarative database provisioning
      databases = {
        # Dispatcharr database
        dispatcharr = {
          owner = "dispatcharr";
          ownerPasswordFile = dispatcharrPasswordPath;
          extensions = [ "uuid-ossp" ];  # Common UUID extension

          # Use the owner-readwrite+readonly-select preset for flexibility
          # This creates:
          # - Full permissions for dispatcharr user
          # - readonly role with SELECT for monitoring/reporting
          permissionsPolicy = "owner-readwrite+readonly-select";
        };
      };
    };
  };
}
