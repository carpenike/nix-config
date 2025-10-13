{ lib, config, ... }:
# PostgreSQL Storage Integration Module
#
# This module reads PostgreSQL instance configuration and creates ZFS datasets.
# It's separated from the main PostgreSQL module to avoid circular dependencies.
#
# Architecture:
# - Reads: config.modules.services.postgresql (one-way dependency)
# - Writes: modules.storage.datasets.services
# - Does NOT read from modules.storage.* (avoids circular dependency)
#
# Integration can be disabled per-instance via:
#   modules.services.postgresql.<instance>.integration.storage.enable = false;
let
  instances = config.modules.services.postgresql or {};
  enabledInstances = lib.filterAttrs (name: cfg: cfg.enable) instances;
in
{
  config = lib.mkIf (enabledInstances != {}) {
    modules.storage.datasets.services = lib.mkMerge (lib.mapAttrsToList (instanceName: instanceCfg:
      let
        dataDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}";
        walArchiveDir = "/var/lib/postgresql/${instanceCfg.version}/${instanceName}-wal-archive";
      in
      # Only create datasets if integration is enabled for this instance
      lib.optionalAttrs (instanceCfg.integration.storage.enable or true) {
        # Data dataset with PostgreSQL-optimal settings
        "postgresql/${instanceName}" = {
          mountpoint = dataDir;
          recordsize = "8K";  # PostgreSQL page size
          compression = "lz4";
          properties = {
            atime = "off";
            xattr = "sa";
            dnodesize = "auto";
          };
          owner = "postgres";
          group = "postgres";
          mode = "0700";
        };

        # WAL archive dataset with sequential write optimization
        "postgresql/${instanceName}-wal" = lib.mkIf (instanceCfg.backup.walArchive.enable or true) {
          mountpoint = walArchiveDir;
          recordsize = "128K";  # Sequential writes
          compression = "lz4";
          properties = {
            atime = "off";
            logbias = "throughput";
            sync = "standard";
          };
          owner = "postgres";
          group = "postgres";
          mode = "0700";
        };
      }
    ) enabledInstances);
  };
}
