{ config, lib, ... }:

let
  domain = config.networking.domain;
  # Use the new unified backup system (modules.services.backup)
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);
in
{
  config = {
    # Loki centralized log aggregation and storage
    # Configured directly on the individual module (not through observability meta-module)
    modules.services.loki = {
      enable = true;
      retentionDays = 30; # Longer retention for primary server

      # ZFS configuration
      zfs = {
        dataset = "tank/services/loki";
        properties = {
          compression = "zstd";
          recordsize = "1M"; # Optimized for log chunks
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
      };

      # Reverse proxy configuration with basic auth
      reverseProxy = {
        enable = true;
        hostName = "loki.${domain}";
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = 3100;
        };
        auth = {
          user = "admin";
          passwordHashEnvVar = "CADDY_LOKI_ADMIN_BCRYPT";
        };
      };

      # Backup configuration - rely on ZFS snapshots for data
      backup = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "logs" "loki" "config" ];
        useSnapshots = true;
        zfsDataset = "tank/services/loki";
        excludePatterns = [
          "**/chunks/**"
          "**/wal/**"
          "**/boltdb-shipper-cache/**"
        ];
      };

      # Preseed for disaster recovery
      preseed = lib.mkIf resticEnabled {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ];
      };
    };

    # ZFS snapshot and replication configuration for Loki dataset
    # Contributes to host-level Sanoid configuration following the contribution pattern
    modules.backup.sanoid.datasets."tank/services/loki" = {
      useTemplate = [ "services" ];
      recursive = false;
      replication = {
        targetHost = "nas-1.holthome.net";
        targetDataset = "backup/forge/zfs-recv/loki";
        sendOptions = "w";
        recvOptions = "u";
        hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
        targetName = "NFS";
        targetLocation = "nas-1";
      };
    };

    # Declare Loki storage dataset (contribution pattern)
    # Optimized for log chunks and WAL files with appropriate compression
    modules.storage.datasets.services.loki = {
      recordsize = "1M";
      compression = "zstd";
      mountpoint = "/var/lib/loki";
      owner = "loki";
      group = "loki";
      mode = "0750";
      properties = {
        "com.sun:auto-snapshot" = "true";
        logbias = "throughput";
        atime = "off";
        primarycache = "metadata";
      };
    };
  };
}
