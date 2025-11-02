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

          # Listen on localhost and Podman bridge for container access
          # Containers connect via host.containers.internal (10.88.0.1)
          # Security: Restrict to specific interfaces instead of all interfaces
          listenAddresses = "127.0.0.1,10.88.0.1";

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
        # DESIGN DECISION: WAL archiving to repo1 (NFS) only - repo2 (R2) is for DR backups
        #
        # The archive_command explicitly targets --repo=1 to clarify intent:
        # WALs are archived continuously to the primary NFS repo for fast local PITR.
        #
        # Repo2 (Cloudflare R2) is intentionally configured as a pure DR repository:
        # - Receives full/diff/incr backups via scheduled jobs (--no-archive-check)
        # - Does NOT receive continuous WAL archiving
        # - Provides geographic redundancy for disaster recovery scenarios
        # - RPO for R2 recovery: last successful backup job (hourly incremental = ~1 hour RPO)
        #
        # This design optimizes for:
        # 1. Fast local recovery (repo1: continuous WALs, low-latency NFS)
        # 2. Cost-effective cloud DR (repo2: backup jobs only, no continuous WAL transfer costs)
        # 3. Operational simplicity (single archive_command, explicit repo targeting)
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

    # Override native PostgreSQL settings to ensure listen_addresses is applied
    # The custom module's listenAddresses may not be taking effect, so we force it here
    services.postgresql.settings = {
      listen_addresses = pkgs.lib.mkForce "127.0.0.1,10.88.0.1";
    };

    # Override authentication to allow container connections from Podman bridge
    # GPT-5 recommendation: Use password-based auth (scram-sha-256) for network connections
    services.postgresql.authentication = ''
      # Local Unix socket connections
      local   all   postgres  peer
      local   all   all       peer

      # Localhost TCP connections
      host    all   all       127.0.0.1/32        scram-sha-256
      host    all   all       ::1/128             scram-sha-256

      # Podman container network (host.containers.internal = 10.88.0.1)
      # Allow password-authenticated connections from containers
      host    all   all       10.88.0.0/16        scram-sha-256
    '';

    # Override PostgreSQL systemd service to allow writes to NFS mount and local spool for pgBackRest
    systemd.services.postgresql = {
      serviceConfig = {
        # Add paths to ReadWritePaths to allow archive_command to write WAL segments
        # Without these, ProtectSystem=strict blocks writes outside /var/lib/postgresql
        # 1. /mnt/nas-postgresql: NFS repo1 (dedicated PostgreSQL backup mount)
        # 2. /var/lib/pgbackrest/spool: Local async spool (archive_command writes here first)
        ReadWritePaths = [
          "/mnt/nas-postgresql"
          "/var/lib/pgbackrest/spool"
        ];
      };

      # CRITICAL: Ensure Podman network exists before PostgreSQL starts
      # The podman0 bridge (10.88.0.1) must be available for PostgreSQL to bind to it
      # Without this, PostgreSQL will only bind to localhost despite the listen_addresses setting
      after = [ "network-online.target" "podman.service" ];
      wants = [ "network-online.target" ];

      # Add a pre-start script to ensure the Podman bridge is up
      # This prevents the "Cannot assign requested address" error when binding to 10.88.0.1
      preStart = ''
        # Wait for Podman bridge interface to be available
        for i in {1..30}; do
          if ${pkgs.iproute2}/bin/ip addr show podman0 | grep -q "10.88.0.1"; then
            echo "Podman bridge (10.88.0.1) is available"
            break
          fi
          echo "Waiting for Podman bridge to come up... ($i/30)"
          # Create the bridge if it doesn't exist (this ensures it's available)
          ${pkgs.podman}/bin/podman network create podman 2>/dev/null || true
          sleep 1
        done

        # Verify the interface is up
        if ! ${pkgs.iproute2}/bin/ip addr show podman0 | grep -q "10.88.0.1"; then
          echo "ERROR: Podman bridge (10.88.0.1) is not available after 30 seconds"
          exit 1
        fi
      '';
    };

    # Automatic restore from backup on server rebuild (disaster recovery)
    # This enables automatic PostgreSQL restore when PGDATA is empty (e.g., fresh install, hardware migration)
    # Uses the standard NixOS services.postgresql namespace (not modules.services.postgresql)
    # See docs/postgresql-auto-restore-homelab.md for details
    services.postgresql.preSeed = {
      enable = true;
      source = {
        stanza = "main";
        repository = 1;  # Use repo1 (NFS) - faster, has WALs, local network
        fallbackRepository = 2;  # Fallback to R2/S3 if NFS fails
        backupSet = "latest";
      };
      # R2 credentials for fallback repository
      environmentFile = config.sops.secrets."restic/r2-prod-env".path;
    };

    # Co-located alert rules for PostgreSQL and pgBackRest
    # These rules are automatically enabled when PostgreSQL is enabled
    # and are aggregated by the alerting module into Prometheus rule files
    modules.alerting.rules = {
      # Metrics scraping failure
      "pgbackrest-metrics-scrape-failed" = {
        type = "promql";
        alertname = "PgBackRestMetricsScrapeFailure";
        expr = "pgbackrest_scrape_success == 0";
        for = "5m";
        severity = "high";
        labels = { service = "postgresql"; category = "monitoring"; };
        annotations = {
          summary = "pgBackRest metrics collection failed on {{ $labels.instance }}";
          description = "Unable to scrape pgBackRest metrics. Check pgbackrest-metrics.service logs.";
        };
      };

      # Stanza unhealthy
      "pgbackrest-stanza-unhealthy" = {
        type = "promql";
        alertname = "PgBackRestStanzaUnhealthy";
        expr = "pgbackrest_stanza_status > 0";
        for = "5m";
        severity = "critical";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest stanza unhealthy on {{ $labels.instance }}";
          description = "Stanza status code: {{ $value }}. Check pgBackRest configuration and logs.";
        };
      };

      # Repository status error
      "pgbackrest-repo-error" = {
        type = "promql";
        alertname = "PgBackRestRepositoryError";
        expr = "pgbackrest_repo_status > 0";
        for = "5m";
        severity = "critical";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest repository error on {{ $labels.instance }}";
          description = "Repository {{ $labels.repo_key }} status code: {{ $value }}. Verify NFS mount and R2 connectivity.";
        };
      };

      # Backup job failure (immediate)
      "pgbackrest-backup-failed" = {
        type = "promql";
        alertname = "PgBackRestBackupFailed";
        expr = "increase(pgbackrest_backup_failed_total[1h]) > 0";
        for = "0m";
        severity = "critical";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest backup job failed on {{ $labels.instance }}";
          description = "A pgBackRest backup job has failed within the last hour. Check pgBackRest logs for details.";
        };
      };

      # Preseed restore failure (disaster recovery)
      "postgresql-preseed-failed" = {
        type = "promql";
        alertname = "PostgreSQLPreseedFailed";
        expr = "postgresql_preseed_status{stanza=\"main\"} == 0";
        for = "0m";
        severity = "critical";
        labels = { service = "postgresql"; category = "disaster-recovery"; };
        annotations = {
          summary = "PostgreSQL pre-seed restore failed on {{ $labels.instance }}";
          description = "The automated restore process from backup failed during disaster recovery. Manual intervention is required to bring the database online. Check postgresql-preseed.service logs with: journalctl -u postgresql-preseed.service -xe";
        };
      };

      # Post-preseed backup failure
      "postgresql-post-preseed-backup-failed" = {
        type = "promql";
        alertname = "PostgreSQLPostPreseedBackupFailed";
        expr = "postgresql_postpreseed_status{stanza=\"main\"} == 0";
        for = "0m";
        severity = "critical";
        labels = { service = "postgresql"; category = "disaster-recovery"; };
        annotations = {
          summary = "PostgreSQL post-preseed backup failed on {{ $labels.instance }}";
          description = "The automated backup after a disaster recovery restore failed. The database is running but has no fresh baseline backup in one or both repositories. Check pgbackrest-post-preseed.service logs with: journalctl -u pgbackrest-post-preseed.service -xe";
        };
      };

      # Full backup stale (>27 hours)
      "pgbackrest-full-backup-stale" = {
        type = "promql";
        alertname = "PgBackRestFullBackupStale";
        expr = "(time() - pgbackrest_backup_last_good_completion_seconds{type=\"full\"}) > 97200";
        for = "1h";
        severity = "high";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest full backup is stale (>27h) on {{ $labels.instance }}";
          description = "Last full backup for repo {{ $labels.repo_key }} was {{ $value | humanizeDuration }} ago. Daily full backups should complete within 27 hours.";
        };
      };

      # Incremental backup stale (>2 hours)
      "pgbackrest-incremental-backup-stale" = {
        type = "promql";
        alertname = "PgBackRestIncrementalBackupStale";
        expr = "(time() - pgbackrest_backup_last_good_completion_seconds{type=\"incr\"}) > 7200";
        for = "30m";
        severity = "high";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest incremental backup is stale (>2h) on {{ $labels.instance }}";
          description = "Last incremental backup for repo {{ $labels.repo_key }} was {{ $value | humanizeDuration }} ago. Hourly incrementals should complete within 2 hours.";
        };
      };

      # WAL archiving stalled (no progress in 15 minutes while database is active)
      "pgbackrest-wal-archiving-stalled" = {
        type = "promql";
        alertname = "PgBackRestWALArchivingStalled";
        expr = "rate(pgbackrest_wal_max_lsn[15m]) == 0 and rate(pg_stat_database_xact_commit[15m]) > 0";
        for = "15m";
        severity = "high";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest WAL archiving appears stalled on {{ $labels.instance }}";
          description = "No WAL progress detected in 15 minutes despite active transactions. Check archive_command and NFS mount health.";
        };
      };

      # Local spool usage high (archive-async backlog)
      "pgbackrest-spool-usage-high" = {
        type = "promql";
        alertname = "PgBackRestSpoolUsageHigh";
        # NOTE: The mountpoint '/var/lib/pgbackrest' is hardcoded and must match the
        # path defined in systemd.tmpfiles.rules in forge/default.nix (line 1028).
        expr = ''(node_filesystem_size_bytes{mountpoint="/var/lib/pgbackrest"} - node_filesystem_avail_bytes{mountpoint="/var/lib/pgbackrest"}) / node_filesystem_size_bytes{mountpoint="/var/lib/pgbackrest"} > 0.8'';
        for = "10m";
        severity = "high";
        labels = { service = "postgresql"; category = "backup"; };
        annotations = {
          summary = "pgBackRest spool usage high on {{ $labels.instance }}";
          description = "Local spool >80% used ({{ $value | humanizePercentage }}). WAL archiving backlog likely. Check NFS repo1 health.";
        };
      };

      # PostgreSQL service down
      "postgresql-service-down" = {
        type = "promql";
        alertname = "PostgreSQLServiceDown";
        expr = ''node_systemd_unit_state{name="postgresql.service",state="active"} == 0'';
        for = "2m";
        severity = "critical";
        labels = { service = "postgresql"; category = "service"; };
        annotations = {
          summary = "PostgreSQL service is down on {{ $labels.instance }}";
          description = "PostgreSQL service is not active. Check systemctl status postgresql.service.";
        };
      };
    };
  };
}
