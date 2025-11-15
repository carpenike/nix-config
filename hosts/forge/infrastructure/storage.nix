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

  # ZFS dataset creation and configuration
  # forge uses the tank pool (2x NVME) for service data
  # tank/services acts as a logical parent (not mounted)
  # Individual services mount to standard FHS paths
  modules.storage = {
    datasets = {
      enable = true;
      parentDataset = "tank/services";
      parentMount = "/srv";  # Fallback for services without explicit mountpoint

      services = {
        # PostgreSQL dataset is now managed by the PostgreSQL module's storage-integration.nix
        # to avoid duplicate dataset creation and configuration conflicts.
        # See: hosts/_modules/nixos/services/postgresql/storage-integration.nix

        # Prometheus time-series database
        # Multi-model consensus (GPT-5 + Gemini 2.5 Pro + Gemini 2.5 Flash): 8.7/10 confidence
        # Verdict: Prometheus TSDB is correct tool; ZFS snapshots are excessive for disposable metrics
        prometheus = {
          recordsize = "128K";  # Aligned with Prometheus WAL segments and 2h block files
          compression = "lz4";  # Minimal overhead; TSDB chunks already compressed
          mountpoint = "/var/lib/prometheus2";
          owner = "prometheus";
          group = "prometheus";
          mode = "0755";
          properties = {
            # Industry best practice: Do NOT snapshot Prometheus TSDB (metrics are disposable)
            # Reasoning: 15-day retention doesn't justify 6-month snapshots; configs in Git, data replaceable
            # CoW amplification during TSDB compaction significantly impacts performance under snapshots
            "com.sun:auto-snapshot" = "false";  # Disable snapshots (was: true)
            logbias = "throughput";  # Optimize for streaming writes, not low-latency sync
            primarycache = "metadata";  # Avoid ARC pollution; Prometheus has its own caching
            atime = "off";  # Reduce metadata writes on read-heavy query workloads
          };
        };

        # Loki log aggregation storage
        # Optimized for log chunks and WAL files with appropriate compression
        loki = {
          recordsize = "1M";      # Optimized for log chunks (large sequential writes)
          compression = "zstd";   # Better compression for text logs than lz4
          mountpoint = "/var/lib/loki";
          owner = "loki";
          group = "loki";
          mode = "0750";
          properties = {
            "com.sun:auto-snapshot" = "true";   # Enable snapshots for log retention
            logbias = "throughput";             # Optimize for streaming log writes
            atime = "off";                      # Reduce metadata overhead
            primarycache = "metadata";          # Don't cache log data in ARC
          };
        };

        # Alertmanager: Using ephemeral root filesystem storage
        # Rationale (GPT-5 validated):
        # - Only stores silences and notification deduplication state
        # - Homelab acceptable to lose silences on restart
        # - Duplicate notifications after restart are tolerable
        # - Dedicated dataset unnecessary for minimal administrative state
        # Location: /var/lib/alertmanager on rpool/local/root (not snapshotted)
        #
        # Updated: Manage Alertmanager storage via ZFS storage module for consistency
        # (still not snapshotted; data is non-critical). This creates the mountpoint
        # with correct ownership/permissions and ensures ordering via zfs-service-datasets.
        alertmanager = {
          recordsize = "16K";     # Small files; minimal overhead
          compression = "lz4";    # Fast, default
          mountpoint = "/var/lib/alertmanager";
          owner = "alertmanager";
          group = "alertmanager";
          mode = "0750";
          properties = {
            "com.sun:auto-snapshot" = "false";  # Do not snapshot (non-critical state)
            logbias = "throughput";
            primarycache = "metadata";
            atime = "off";
          };
        };
      };

      # Utility datasets (not under parentDataset/services)
      utility = {
        # Temporary dataset for ZFS clone-based backups
        # Used by snapshot-based backup services (dispatcharr, plex)
        # to avoid .zfs directory issues when backing up mounted filesystems
        "tank/temp" = {
          mountpoint = "none";
          compression = "lz4";
          recordsize = "128K";
          properties = {
            "com.sun:auto-snapshot" = "false";  # Don't snapshot temporary clones
          };
        };
      };
    };

    # Shared NFS mount for media access from NAS
    nfsMounts.media = {
      enable = true;
      automount = false;  # Disable automount for always-on media services (prevents idle timeout cascade stops)
      server = "nas.holthome.net";
      remotePath = "/mnt/tank/share";
      localPath = "/mnt/data";  # Mount point for shared NAS data (contains media/, backups/, etc.)
      group = "media";
      mode = "02775";  # setgid bit ensures new files inherit media group
      mountOptions = [ "nfsvers=4.2" "timeo=60" "retry=5" "rw" "noatime" ];
    };
  };
}
