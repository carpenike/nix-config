{ config, ... }:

{
  # System-level ZFS storage management
  # This file contains:
  # - Sanoid templates (reusable snapshot/retention policies)
  # - System-level datasets (home, persist)
  # - PostgreSQL-specific datasets (controlled by postgresql service)
  # - Parent container dataset (tank/services)
  #
  # Service-specific datasets are configured in their respective service files
  # following the contribution pattern (e.g., services/sonarr.nix configures tank/services/sonarr)

  modules.backup.sanoid = {
    enable = true;
    sshKeyPath = config.sops.secrets."zfs-replication/ssh-key".path;
    snapshotInterval = "*:0/5";  # Run snapshots every 5 minutes (for high-frequency datasets)
    replicationInterval = "*:0/15";  # Run replication every 15 minutes for faster DR

    # Retention templates for different data types
    # Services reference these via: useTemplate = [ "services" ];
    templates = {
      production = {
        hourly = 24;      # 24 hours
        daily = 7;        # 1 week
        weekly = 4;       # 1 month
        monthly = 3;      # 3 months
        autosnap = true;
        autoprune = true;
      };
      services = {
        hourly = 48;      # 2 days
        daily = 14;       # 2 weeks
        weekly = 8;       # 2 months
        monthly = 6;      # 6 months
        autosnap = true;
        autoprune = true;
      };
      # High-frequency snapshots for PostgreSQL WAL archives
      # Provides 5-minute RPO for database point-in-time recovery
      wal-frequent = {
        frequently = 12;  # Keep 12 five-minute snapshots (1 hour of frequent retention)
        hourly = 48;      # 2 days of hourly rollup
        daily = 7;        # 1 week of daily rollup
        autosnap = true;
        autoprune = true;
      };
    };

    # System-level dataset configuration
    datasets = {
      # Home directory - user data
      "rpool/safe/home" = {
        useTemplate = [ "production" ];
        recursive = false;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/home";
          sendOptions = "w";  # Raw encrypted send
          recvOptions = "u";  # Don't mount on receive
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # System persistence - configuration and state
      "rpool/safe/persist" = {
        useTemplate = [ "production" ];
        recursive = false;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/persist";
          sendOptions = "w";
          recvOptions = "u";
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # Parent service dataset - metadata only, children managed by their respective modules
      # This dataset itself doesn't get snapshotted (recursive = false)
      # Individual service modules (dispatcharr, sonarr, etc.) configure their own snapshots
      # Note: No useTemplate needed - this is just a logical container, not an actual snapshot target
      "tank/services" = {
        recursive = false;  # Don't snapshot children - they manage themselves
        autosnap = false;   # Don't snapshot the parent directory itself
        autoprune = false;
        # No replication - individual services handle their own replication
      };

      # PostgreSQL-specific datasets
      # Explicitly disable snapshots on PostgreSQL dataset (rely on pgBackRest)
      "tank/services/postgresql" = {
        autosnap = false;
        autoprune = false;
        recursive = false;
      };

      # Explicitly disable snapshots/replication on Prometheus dataset (metrics are disposable)
      # Rationale (multi-model consensus 8.7/10 confidence):
      # - Industry best practice: Don't backup Prometheus TSDB, only configs/dashboards
      # - 15-day metric retention doesn't justify 6-month snapshot policy
      # - CoW amplification during TSDB compaction degrades performance
      # - Losing metrics on rebuild is acceptable; alerting/monitoring continues immediately
      "tank/services/prometheus" = {
        autosnap = false;
        autoprune = false;
        recursive = false;
      };
    };
  };
}
