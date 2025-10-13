{ lib, config, ... }:
# PostgreSQL Backup Integration Module
#
# This module reads PostgreSQL configuration and creates Restic backup jobs.
# It's separated from the main PostgreSQL module to avoid circular dependencies.
#
# Architecture:
# - Reads: config.modules.services.postgresql (one-way dependency)
# - Writes: modules.backup.restic.jobs
# - Does NOT read from modules.backup.* (avoids circular dependency)
let
  cfg = config.modules.services.postgresql;
in
{
  config = lib.mkIf (cfg.enable && config.modules.backup.enable or false && cfg.backup.restic.enable && (cfg.integration.backup.enable or true)) {
    modules.backup.restic.jobs = {
      # WAL archive backup job
      # NOTE: This uses the global backup schedule from modules.backup.schedule
      # For more frequent WAL archiving, consider a separate systemd timer
      postgresql-wal = {
        enable = true;
        paths = [ cfg.walArchiveDir ];
        excludePatterns = [
          "**/*.tmp"
          "**/*.partial"
        ];
        repository = cfg.backup.restic.repositoryName;
        tags = [ "postgresql" "main" "wal-archive" "pitr" ];
      };

      # Base backup job
      postgresql-base = {
        enable = true;
        paths = [ "/var/backup/postgresql/main" ];
        excludePatterns = [
          "**/postmaster.pid"
          "**/postmaster.opts"
          "**/*.tmp"
          "**/pg_log/*"
          "**/pg_xlog/*"
          "**/pg_wal/*"
        ];
        repository = cfg.backup.restic.repositoryName;
        tags = [ "postgresql" "main" "base-backup" "pitr" ];
      };
    };
  };
}
