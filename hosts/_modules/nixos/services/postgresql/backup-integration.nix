{ lib, config, ... }:
# PostgreSQL Backup Integration Module
#
# This module reads PostgreSQL instance configuration and creates Restic backup jobs.
# It's separated from the main PostgreSQL module to avoid circular dependencies.
#
# Architecture:
# - Reads: config.modules.services.postgresql (one-way dependency)
# - Writes: modules.backup.restic.jobs
# - Does NOT read from modules.backup.* (avoids circular dependency)
let
  instances = config.modules.services.postgresql or {};
  enabledInstances = lib.filterAttrs (name: cfg: cfg.enable) instances;
in
{
  config = lib.mkIf (enabledInstances != {} && config.modules.backup.enable or false) {
    modules.backup.restic.jobs = lib.mkMerge (lib.mapAttrsToList (instanceName: instanceCfg:
      let
        walArchiveDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}-wal-archive";
      in
      # Only create backup jobs if both backup.restic AND integration.backup are enabled
      lib.optionalAttrs (instanceCfg.backup.restic.enable && (instanceCfg.integration.backup.enable or true)) {
        # WAL archive backup job
        # NOTE: This uses the global backup schedule from modules.backup.schedule
        # For more frequent WAL archiving, consider a separate systemd timer
        "postgresql-${instanceName}-wal" = {
          enable = true;
          paths = [ walArchiveDir ];
          excludePatterns = [
            "**/*.tmp"
            "**/*.partial"
          ];
          repository = instanceCfg.backup.restic.repositoryName;
          tags = [ "postgresql" instanceName "wal-archive" "pitr" ];
        };

        # Base backup job
        "postgresql-${instanceName}-base" = {
          enable = true;
          paths = [ "/var/backup/postgresql/${instanceName}" ];
          excludePatterns = [
            "**/postmaster.pid"
            "**/postmaster.opts"
            "**/*.tmp"
            "**/pg_log/*"
            "**/pg_xlog/*"
            "**/pg_wal/*"
          ];
          repository = instanceCfg.backup.restic.repositoryName;
          tags = [ "postgresql" instanceName "base-backup" "pitr" ];
        };
      }
    ) enabledInstances);
  };
}
