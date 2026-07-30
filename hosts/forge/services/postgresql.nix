{ config, pkgs, lib, ... }:
# PostgreSQL Configuration for forge
#
# Provides a shared PostgreSQL instance for services on forge that need a database backend.
# Initial use case: dispatcharr (IPTV stream management)
#
# Architecture:
# - Single PostgreSQL 17 instance
# - Databases provisioned declaratively via modules.services.postgresql.databases
# - Automatic role creation with SOPS-managed passwords
# - ZFS dataset with PostgreSQL-optimal settings (8K recordsize)
# - Backup integration via pgBackRest (replaces custom Restic approach)
# - Health monitoring and notifications
#
# Infrastructure Contributions:
#   - Backup: Managed by pgBackRest (see pgbackrest.nix), NOT standard backup module
#   - Sanoid: Defined in this file (PostgreSQL-specific snapshot policy)
#   - Monitoring: Database-specific alerts (connections, replication, backup status)
#
# Secret paths are passed via postgresSecrets parameter (defined in forge/default.nix)
# to avoid circular dependencies in module evaluation
#
let
  postgresql16Package = pkgs.postgresql_16.withPackages (ps: [ ps.timescaledb ]);
  postgresql17Package = pkgs.postgresql_17.withPackages (ps: [ ps.timescaledb ]);
  postgresqlMajorUpgrade = pkgs.writeShellApplication {
    name = "postgresql-major-upgrade";
    runtimeInputs = with pkgs; [ coreutils gawk procps systemd ];
    text = ''
      export PG_OLD_BIN=${postgresql16Package}/bin
      export PG_NEW_BIN=${postgresql17Package}/bin
      export PG_OLD_DATA=/var/lib/postgresql/16
      export PG_NEW_DATA=/var/lib/postgresql/17
      export PG_WORK_DIR=/var/lib/postgresql/upgrade-16-to-17
      export PG_OLD_VERSION=16
      export PG_NEW_VERSION=17
      export PG_INITDB_LOCALE=en_US.UTF-8
      export PG_MAINTENANCE_MARKER=/run/postgresql-major-upgrade-target

      ${builtins.readFile ../../../scripts/postgresql-major-upgrade.sh}
    '';
  };

  # Allow operators to override which Podman CIDRs can reach PostgreSQL without
  # editing the pg_hba.conf snippet directly. If modules.services.postgresql.podmanCidrs
  # is unset, fall back to the traditional 10.88.0.0/16 bridge network.
  podmanAccessCidrs = lib.attrByPath [ "modules" "services" "postgresql" "podmanCidrs" ] [ "10.88.0.0/16" ] config;
  podmanAuthBlock = lib.concatMapStrings (cidr: "host    all   all       ${cidr}        scram-sha-256\n") podmanAccessCidrs;
  serviceEnabled = config.modules.services.postgresql.enable or false;
in
{
  config = lib.mkMerge [
    {
      # Enable PostgreSQL service
      modules.services.postgresql = {
        enable = true;
        version = "17";
        port = 5432;

        # Listen on localhost and Podman bridge for container access
        # Containers connect via host.containers.internal (10.88.0.1)
        # Security: Restrict to specific interfaces instead of all interfaces
        listenAddresses = "127.0.0.1,10.88.0.1";

        # Open firewall for container access (podman bridge interfaces)
        openFirewall = true;

        # Conservative memory settings for a shared host. PostgreSQL's measured
        # NVMe read latency is low, while forge runs many memory-heavy services.
        sharedBuffers = "256MB";
        effectiveCacheSize = "1GB";
        maintenanceWorkMem = "128MB";
        workMem = "16MB";

        # Additional settings via extraSettings
        extraSettings = {
          # WAL settings for pgBackRest PITR
          wal_level = "replica"; # Required for pgBackRest
          wal_compression = "on";
          max_wal_size = "2GB";
          min_wal_size = "512MB";
          archive_mode = "on";
          # DESIGN DECISION: Archive WAL continuously to both pgBackRest repositories.
          #
          # pgBackRest archive-push writes each segment to repo1 (NFS) and repo2 (R2).
          # archive-async decouples PostgreSQL from repository latency through the local
          # spool, while archive_timeout forces a segment switch every five minutes.
          # This gives both repositories PITR coverage with a nominal five-minute RPO.
          # Scheduled full and incremental jobs maintain independent backup chains;
          # repository-independent restore remains a separate, unproven DR requirement.
          archive_command = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=main archive-push %p";
          archive_timeout = "300"; # Force WAL switch every 5 minutes (bounds RPO)

          # Checkpoint settings
          checkpoint_timeout = "15min";
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
          # Surface long-running maintenance and checkpoint behavior for easier diagnostics
          log_checkpoints = "on";
          log_lock_waits = "on";
          log_autovacuum_min_duration = "1s";
          log_temp_files = "10MB";
          idle_in_transaction_session_timeout = "10min";
          track_io_timing = "on";
          autovacuum_max_workers = "5";
          autovacuum_naptime = "30s";
          autovacuum_vacuum_scale_factor = "0.05";
          autovacuum_analyze_scale_factor = "0.02";
          autovacuum_work_mem = "128MB";
        };

        # Disable old backup integration (now using pgBackRest directly)
        integration.backup.enable = false;
        backup.walArchive.enable = false; # Disable module's archive_command (using pgBackRest instead)
        backup.baseBackup.enable = false; # Disable module's base backup (using pgBackRest instead)

        # Enable health monitoring
        healthCheck.enable = true;

        # Note: Individual databases are declared by their respective service modules
        # See dispatcharr.nix, etc. for database provisioning
        databases = { };
      };

      # Override native PostgreSQL settings to ensure listen_addresses is applied
      # The custom module's listenAddresses may not be taking effect, so we force it here
      services.postgresql.settings = {
        listen_addresses = pkgs.lib.mkForce "127.0.0.1,10.88.0.1";
        shared_preload_libraries = "timescaledb,pg_stat_statements";
      };

      # Resolve extension binaries from the selected PostgreSQL major version.
      services.postgresql.extensions = ps: [
        ps.timescaledb
      ];

      environment.systemPackages = [ postgresqlMajorUpgrade ];

      # Override authentication to allow container connections from Podman bridge
      # GPT-5 recommendation: Use password-based auth (scram-sha-256) for network connections
      services.postgresql.authentication = ''
              # Local Unix socket connections
              # Allow Home Assistant recorder to use password auth even on unix sockets
              local   home_assistant   hass_recorder   scram-sha-256
              local   all   postgres  peer
              local   all   all       peer

              # Localhost TCP connections
              host    all   all       127.0.0.1/32        scram-sha-256
              host    all   all       ::1/128             scram-sha-256

          # Podman container networks (host.containers.internal = 10.88.0.1 by default)
          # Allow password-authenticated connections from containers. Operators can
          # override the list via modules.services.postgresql.podmanCidrs.
        ${podmanAuthBlock}
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

        # REMOVED: EnvironmentFile and environment variables for R2 credentials
        # These were overriding the config file values and preventing WAL archiving.
        # The pgbackrest-config-generator.service now manages credentials in /etc/pgbackrest.conf
        # which is the single source of truth for pgBackRest configuration.

        # CRITICAL: Ensure Podman network exists before PostgreSQL starts
        # The podman0 bridge (10.88.0.1) must be available for PostgreSQL to bind to it
        # Without this, PostgreSQL will only bind to localhost despite the listen_addresses setting
        after = [ "network-online.target" "podman.service" "sys-devices-virtual-net-podman0.device" ];
        wants = [ "network-online.target" ];
        # Require the podman0 device to exist before starting (stronger than after)
        requires = [ "sys-devices-virtual-net-podman0.device" ];

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

      # NOTE: postgresql-readiness-wait.service is provided by modules/nixos/services/postgresql
      # It polls pg_isready until the database is ready, used by pgbackrest-stanza-create

      # Automatic restore from backup on server rebuild (disaster recovery)
      # This enables automatic PostgreSQL restore when PGDATA is empty (e.g., fresh install, hardware migration)
      # Uses the standard NixOS services.postgresql namespace (not modules.services.postgresql)
      # See docs/postgresql-auto-restore-homelab.md for details
      services.postgresql.preSeed = {
        enable = true;
        source = {
          stanza = "main";
          repository = 1; # Use repo1 (NFS) - faster, has WALs, local network
          fallbackRepository = 2; # Fallback to R2/S3 if NFS fails
          backupSet = "latest";
        };
      };

      systemd.services.postgresql-preseed = {
        # Ensure config file is generated before preseed attempts restore
        after = [ "pgbackrest-config-generator.service" ];
        requires = [ "pgbackrest-config-generator.service" ];
        unitConfig.OnSuccess = "pgbackrest-post-preseed.service";
      };

    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.postgresql.protection = {
        class = "critical";
        objectives = {
          onsiteRpoSeconds = 300;
          offsiteRpoSeconds = 300;
          rtoSeconds = 7200;
        };
        requiredTiers = [
          "nas-backup"
          "offsite-backup"
          "automated-restore"
          "independent-restore"
        ];
        consistency = "transaction-consistent";
        validator = "postgresql-cluster-health";
        allowEmptyBootstrap = false;
        mechanism = {
          name = "pgbackrest";
          reason = "Continuous WAL archiving and application-consistent backups provide PITR.";
        };
      };

      # Co-located alert rules for PostgreSQL
      # pgBackRest alerts have been moved to pgbackrest.nix for proper service co-location
      # These rules are automatically enabled when PostgreSQL is enabled
      # and are aggregated by the alerting module into Prometheus rule files
      modules.alerting.rules = {
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

        # PostgreSQL Performance Monitoring Alerts
        # These alerts monitor database performance metrics from postgres_exporter
        # Previously centralized in infrastructure/monitoring.nix, now co-located with service config

        # Database server connectivity
        "postgres-down" = {
          type = "promql";
          alertname = "PostgresDown";
          expr = "pg_up == 0";
          for = "2m";
          severity = "critical";
          labels = { service = "postgresql"; category = "availability"; };
          annotations = {
            summary = "PostgreSQL is down on {{ $labels.instance }}";
            description = "PostgreSQL database server is not responding. Check service status.";
          };
        };

        # Connection pool exhaustion
        "postgres-too-many-connections" = {
          type = "promql";
          alertname = "PostgresTooManyConnections";
          expr = "sum(pg_stat_database_numbackends) / avg(pg_settings_max_connections) * 100 > 80";
          for = "5m";
          severity = "high";
          labels = { service = "postgresql"; category = "capacity"; };
          annotations = {
            summary = "PostgreSQL connection usage high on {{ $labels.instance }}";
            description = "PostgreSQL is using {{ $value }}% of max connections. Consider increasing max_connections or investigating connection leaks.";
          };
        };

        # Query performance degradation
        "postgres-slow-queries" = {
          type = "promql";
          alertname = "PostgresSlowQueries";
          expr = "increase(pg_stat_database_tup_returned[5m]) / increase(pg_stat_database_tup_fetched[5m]) < 0.1";
          for = "10m";
          severity = "medium";
          labels = { service = "postgresql"; category = "performance"; };
          annotations = {
            summary = "PostgreSQL slow queries detected on {{ $labels.instance }}";
            description = "Database {{ $labels.datname }} has low efficiency ratio. Check for missing indexes or inefficient queries.";
          };
        };

        # Transaction deadlocks
        "postgres-deadlocks" = {
          type = "promql";
          alertname = "PostgresDeadlocks";
          expr = "increase(pg_stat_database_deadlocks[1h]) > 0";
          for = "0m";
          severity = "medium";
          labels = { service = "postgresql"; category = "performance"; };
          annotations = {
            summary = "PostgreSQL deadlocks detected on {{ $labels.instance }}";
            description = "Database {{ $labels.datname }} has {{ $value }} deadlocks in the last hour. Review transaction patterns.";
          };
        };

        # WAL archiving health (critical for backup integrity)
        "postgres-wal-archiving-failures" = {
          type = "promql";
          alertname = "PostgresWalArchivingFailures";
          expr = "increase(pg_stat_archiver_failed_count[15m]) > 0";
          for = "15m";
          severity = "high";
          labels = { service = "postgresql"; category = "archiving"; };
          annotations = {
            summary = "PostgreSQL WAL archiving failures on {{ $labels.instance }}";
            description = "WAL archiving has failed {{ $value }} times in the last 15 minutes. Check archive_command and destination.";
          };
        };

        # Database size monitoring
        "postgres-database-size-large" = {
          type = "promql";
          alertname = "PostgresDatabaseSizeLarge";
          expr = "pg_database_size_bytes > 20 * 1024 * 1024 * 1024"; # 20 GiB
          for = "30m";
          severity = "medium";
          labels = { service = "postgresql"; category = "capacity"; };
          annotations = {
            summary = "PostgreSQL database {{ $labels.datname }} is large on {{ $labels.instance }}";
            description = "Database {{ $labels.datname }} is {{ $value }} bytes (>20 GiB). Consider cleanup or archiving.";
          };
        };
      };

      # Declare backup policy: Don't snapshot PostgreSQL (pgBackRest handles backups)
      modules.backup.sanoid.datasets."tank/services/postgresql" = {
        autosnap = false;
        autoprune = false;
        recursive = false;
      };
    })
  ];
}
