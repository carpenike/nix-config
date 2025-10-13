{ lib, config, ... }:
# PostgreSQL Storage Integration Module
#
# This module reads PostgreSQL configuration and creates ZFS datasets.
# It's separated from the main PostgreSQL module to avoid circular dependencies.
#
# Architecture:
# - Reads: config.modules.services.postgresql (one-way dependency)
# - Writes: modules.storage.datasets.services
# - Does NOT read from modules.storage.* (avoids circular dependency)
#
# Integration can be disabled via:
#   modules.services.postgresql.integration.storage.enable = false;
let
  cfg = config.modules.services.postgresql;
in
{
  config = lib.mkIf (cfg.enable && (cfg.integration.storage.enable or true)) {
    modules.storage.datasets.services = {
      # Data dataset with PostgreSQL-optimal settings
      "postgresql/main" = {
        mountpoint = cfg.dataDir;
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
      # Only create if WAL archiving is explicitly enabled
      "postgresql/main-wal" = lib.mkIf (cfg.backup.walArchive.enable or false) {
        mountpoint = cfg.walArchiveDir;
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
    };
  };
}
