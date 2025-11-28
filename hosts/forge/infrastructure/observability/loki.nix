{ config, lib, ... }:

let
  # Use the new unified backup system (modules.services.backup)
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);
in
{
  config = {
    # Loki centralized log aggregation and storage
    modules.services.observability.loki = {
      enable = true;
      retentionDays = 30; # Longer retention for primary server
      zfsDataset = "tank/services/loki";
      preseed = lib.mkIf resticEnabled {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ]; # Restic excluded: preserve ZFS lineage, use only for manual DR
      };
    };

    # Loki reverse proxy configuration
    modules.services.observability.reverseProxy = {
      enable = true;
      subdomain = "loki";
      auth = {
        user = "admin";
        passwordHashEnvVar = "CADDY_LOKI_ADMIN_BCRYPT";
      };
    };

    # Loki backup configuration
    modules.services.observability.loki.backup = {
      enable = true;
      includeChunks = false; # Rely on ZFS snapshots for data
    };

    # Enable Loki alerting rules
    modules.services.observability.alerts.enable = true;

    # ZFS snapshot and replication configuration for Loki dataset
    # Contributes to host-level Sanoid configuration following the contribution pattern
    modules.backup.sanoid.datasets."tank/services/loki" = {
      useTemplate = [ "services" ]; # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
      recursive = false;
      replication = {
        targetHost = "nas-1.holthome.net";
        targetDataset = "backup/forge/zfs-recv/loki";
        sendOptions = "w"; # Raw encrypted send (no property preservation)
        recvOptions = "u"; # Don't mount on receive
        hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
        # Consistent naming for Prometheus metrics
        targetName = "NFS";
        targetLocation = "nas-1";
      };
    };

    # Declare Loki storage dataset (contribution pattern)
    # Optimized for log chunks and WAL files with appropriate compression
    modules.storage.datasets.services.loki = {
      recordsize = "1M"; # Optimized for log chunks (large sequential writes)
      compression = "zstd"; # Better compression for text logs than lz4
      mountpoint = "/var/lib/loki";
      owner = "loki";
      group = "loki";
      mode = "0750";
      properties = {
        "com.sun:auto-snapshot" = "true"; # Enable snapshots for log retention
        logbias = "throughput"; # Optimize for streaming log writes
        atime = "off"; # Reduce metadata overhead
        primarycache = "metadata"; # Don't cache log data in ARC
      };
    };
  };
}
