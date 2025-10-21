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
      "postgresql" = {
        mountpoint = cfg.dataDir;
        recordsize = "8K";  # PostgreSQL page size
        compression = "lz4";
        properties = {
          "com.sun:auto-snapshot" = "false";  # PostgreSQL backups via pgBackRest (application-consistent)
          atime = "off";
          xattr = "sa";
          dnodesize = "auto";
          logbias = "throughput";  # Optimize for database throughput over latency
          primarycache = "metadata";  # ARC caches metadata only; PostgreSQL handles data caching
          redundant_metadata = "most";  # Balance between redundancy and performance
          sync = "standard";  # Use ZIL for synchronous writes (PostgreSQL WAL)
        };
        owner = "postgres";
        group = "postgres";
        mode = "0700";
      };

      # WAL archive dataset removed - obsolete with pgBackRest
      # pgBackRest now handles all WAL archiving directly to its own repository
    };
  };
}
