# PostgreSQL Hybrid Backup Integration
#
# Integrates with existing pgBackRest setup while adding:
# - Restic offsite backup of pgBackRest archives
# - Unified monitoring via textfile collector
# - Verification framework for PostgreSQL backups

{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.backup;
  postgresCfg = cfg.postgres or { };

  # Check if PostgreSQL is enabled
  postgresqlEnabled = config.modules.services.postgresql.enable or false;

in
{
  options.modules.services.backup.postgres = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = postgresqlEnabled;
      description = "Enable PostgreSQL backup integration";
    };

    pgbackrest = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enableOffsite = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable offsite Restic backup of pgBackRest archives";
          };

          offsiteRepository = lib.mkOption {
            type = lib.types.str;
            default = "r2-offsite";
            description = "Restic repository for pgBackRest offsite backups";
          };

          archivePath = lib.mkOption {
            type = lib.types.path;
            default = "/mnt/nas-postgresql/pgbackrest";
            description = "Path to pgBackRest archives";
          };

          excludePatterns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "**/lock/*"
              "**/tmp/*"
              "**/*.tmp"
            ];
            description = "Patterns to exclude from pgBackRest offsite backup";
          };
        };
      };
      default = { };
      description = "pgBackRest integration configuration";
    };

    verification = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable PostgreSQL backup verification";
          };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "weekly";
            description = "Verification schedule";
          };

          testDatabase = lib.mkOption {
            type = lib.types.str;
            default = "postgres";
            description = "Database to use for verification tests";
          };
        };
      };
      default = { };
      description = "PostgreSQL backup verification";
    };
  };

  config = lib.mkIf (cfg.enable && postgresCfg.enable && postgresqlEnabled) {
    # Restic job for pgBackRest offsite backup
    modules.services.backup.restic.jobs.postgres-pgbackrest = lib.mkIf postgresCfg.pgbackrest.enableOffsite {
      enable = true;
      repository = postgresCfg.pgbackrest.offsiteRepository;
      paths = [ postgresCfg.pgbackrest.archivePath ];
      tags = [ "postgresql" "pgbackrest" "database" ];
      excludePatterns = postgresCfg.pgbackrest.excludePatterns;
      frequency = "daily";

      # Resources appropriate for database backups
      resources = {
        memory = "1G";
        memoryReservation = "512M";
        cpus = "1.0";
      };

      # No snapshots needed - pgBackRest handles consistency
      useSnapshots = false;

      preBackupScript = ''
        # Verify pgBackRest NFS mount is available (check parent mount point)
        if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/nas-postgresql; then
          echo "ERROR: pgBackRest NFS mount /mnt/nas-postgresql not available"
          exit 1
        fi

        # Verify the pgBackRest directory exists
        if [ ! -d "${postgresCfg.pgbackrest.archivePath}" ]; then
          echo "ERROR: pgBackRest archive path ${postgresCfg.pgbackrest.archivePath} does not exist"
          exit 1
        fi

        # Check that pgBackRest has recent backups
        if ! ls ${postgresCfg.pgbackrest.archivePath}/backup/*/backup.info >/dev/null 2>&1; then
          echo "WARNING: No pgBackRest backup.info found, continuing anyway"
        fi
      '';

      postBackupScript = ''
        # Record pgBackRest backup metrics
        METRICS_FILE="/var/lib/node_exporter/textfile_collector/postgres_backup.prom"
        {
          echo "# HELP postgres_pgbackrest_offsite_backup_status pgBackRest offsite backup status"
          echo "# TYPE postgres_pgbackrest_offsite_backup_status gauge"
          echo "postgres_pgbackrest_offsite_backup_status{hostname=\"${config.networking.hostName}\"} 1"

          echo "# HELP postgres_pgbackrest_offsite_backup_timestamp pgBackRest offsite backup timestamp"
          echo "# TYPE postgres_pgbackrest_offsite_backup_timestamp gauge"
          echo "postgres_pgbackrest_offsite_backup_timestamp{hostname=\"${config.networking.hostName}\"} $(date +%s)"
        } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
      '';
    };

    # Override systemd service to use postgres as primary group for reading pgBackRest archives
    # Note: NFS requires the group to be primary, not supplementary, for permission checks
    systemd.services.restic-backup-postgres-pgbackrest = lib.mkIf postgresCfg.pgbackrest.enableOffsite {
      serviceConfig = {
        Group = lib.mkForce "postgres";
      };
    };

    # PostgreSQL backup verification service
    systemd.services.postgres-backup-verification = lib.mkIf postgresCfg.verification.enable {
      description = "PostgreSQL backup verification";
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";

        ExecStart = pkgs.writeShellScript "postgres-backup-verification" ''
          set -euo pipefail

          METRICS_FILE="/var/lib/node_exporter/textfile_collector/postgres_verification.prom"
          START_TIME=$(date +%s)

          # Cleanup function for metrics
          cleanup() {
            local exit_code=$?
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            {
              echo "# HELP postgres_backup_verification_status PostgreSQL backup verification status"
              echo "# TYPE postgres_backup_verification_status gauge"
              echo "postgres_backup_verification_status{hostname=\"${config.networking.hostName}\"} $([[ $exit_code -eq 0 ]] && echo 1 || echo 0)"

              echo "# HELP postgres_backup_verification_duration_seconds Verification duration"
              echo "# TYPE postgres_backup_verification_duration_seconds gauge"
              echo "postgres_backup_verification_duration_seconds{hostname=\"${config.networking.hostName}\"} $duration"

              if [[ $exit_code -eq 0 ]]; then
                echo "# HELP postgres_backup_verification_last_success Last successful verification"
                echo "# TYPE postgres_backup_verification_last_success gauge"
                echo "postgres_backup_verification_last_success{hostname=\"${config.networking.hostName}\"} $end_time"
              fi
            } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
          }
          trap cleanup EXIT

          echo "Starting PostgreSQL backup verification..."

          # Check pgBackRest repository status
          if ! ${pkgs.pgbackrest}/bin/pgbackrest --config=/etc/pgbackrest/pgbackrest.conf info; then
            echo "ERROR: pgBackRest repository check failed"
            exit 1
          fi

          # Verify recent backup exists
          if ! ${pkgs.pgbackrest}/bin/pgbackrest --config=/etc/pgbackrest/pgbackrest.conf info \
              | grep -q "$(date -d '1 day ago' '+%Y-%m-%d')"; then
            echo "WARNING: No recent backup found within 24 hours"
          fi

          # Test database connectivity and basic operations
          if ! ${pkgs.postgresql}/bin/psql -d ${postgresCfg.verification.testDatabase} -c "SELECT version();" >/dev/null; then
            echo "ERROR: Database connectivity test failed"
            exit 1
          fi

          echo "PostgreSQL backup verification completed successfully"
        '';
      };
    };

    # Timer for verification
    systemd.timers.postgres-backup-verification = lib.mkIf postgresCfg.verification.enable {
      description = "PostgreSQL backup verification timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = postgresCfg.verification.schedule;
        Persistent = true;
      };
    };

    # Ensure pgBackRest configuration exists
    assertions = lib.mkIf postgresCfg.pgbackrest.enableOffsite [
      {
        assertion = lib.hasAttr postgresCfg.pgbackrest.offsiteRepository cfg.repositories;
        message = "pgBackRest offsite repository '${postgresCfg.pgbackrest.offsiteRepository}' must be defined in backup repositories";
      }
    ];

    # Runtime check for pgBackRest path in the backup script itself
    # Note: Path existence is checked at runtime, not evaluation time
  };
}
