{ config, lib, ... }:

# Forge Backup Configuration
#
# PostgreSQL backups are handled by pgBackRest (see postgresql.nix and default.nix)
# - Application-consistent backups with Point-in-Time Recovery (PITR)
# - Dual-repository with full PITR on both: Local NFS (repo1) + Offsite R2 (repo2)
# - Integrated with monitoring and Prometheus metrics
# - Archive-async with local spool for high availability
#
# PostgreSQL Backup Strategy:
# - pgBackRest repo1 (NFS): Full/incr backups + continuous WAL archiving
#   * 7-day retention
#   * Full PITR capability
#   * Primary recovery source (fastest)
#
# - pgBackRest repo2 (Cloudflare R2): Full/incr backups + continuous WAL archiving
#   * 30-day retention
#   * Full PITR capability
#   * Geographic redundancy for disaster recovery
#   * Cost-effective (R2 has zero egress fees)
#
# - ZFS snapshots: Service data only (tank/services excluding PostgreSQL PGDATA)
# - ZFS replication: Service data to nas-1 every 15 minutes (configured in default.nix, excludes PostgreSQL)
#
# This file manages Restic backups for non-database services:
# - System state (/home, /persist)
# - Service configurations
# - Documentation
#
# PostgreSQL Recovery Process:
# PostgreSQL backups are now handled entirely by pgBackRest (not Restic)
# For recovery procedures, see: /Users/ryan/src/nix-config/docs/postgresql-pitr-guide.md
# WAL archive is managed by pgBackRest at: /mnt/nas-postgresql/pgbackrest/archive/
# No separate WAL restoration needed - pgBackRest handles this automatically
#
# Setup Requirements:
# 1. Create Cloudflare R2 bucket: "nix-homelab-backups"
# 2. Generate R2 API token (read/write access)
# 3. Add to secrets.sops.yaml:
#    restic/r2-env: |
#      AWS_ACCESS_KEY_ID=<your_key>
#      AWS_SECRET_ACCESS_KEY=<your_secret>
# 4. Deploy configuration and verify first backup succeeds

{
  config = {
    # Note: restic-backup user/group created by backup module
    # (hosts/_modules/nixos/backup.nix - no need to duplicate here)

    # Mount NFS shares from nas-1 for backups
    # Restic backup storage (non-database data)
    # Prefer declarative fileSystems with systemd automount and explicit network dependency
    fileSystems."/mnt/nas-backup" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/restic";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "noauto"                          # don’t mount at boot; automount will trigger on access
        "_netdev"                         # mark as network device
        "x-systemd.automount"             # create/enable automount unit
        "x-systemd.idle-timeout=600"      # unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"     # fail fast if NAS is down
        "x-systemd.force-unmount=true"    # force unmount on shutdown to avoid hangs
        "x-systemd.after=network-online.target"
        "x-systemd.requires=network-online.target"
      ];
    };

    # Static systemd.mount removed; rely on fileSystems automount and RequiresMountsFor in dependent services.

    # PostgreSQL backups via pgBackRest (separate mount for isolation)
    # Hardened for pgBackRest WAL archiving reliability
    # CRITICAL: No automount - must be always available for:
    #   - postgresql-preseed service (runs early, namespace isolated)
    #   - pgbackrest-stanza-create (boot-time initialization)
    #   - WAL archiving (continuous, can't tolerate mount delays)
    fileSystems."/mnt/nas-postgresql" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/postgresql";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "hard"              # Retry indefinitely on timeout (don't fail)
        "timeo=600"         # 60-second timeout (10× default of 6s)
        "retrans=3"         # Retry 3 times before reporting error
        "_netdev"           # Wait for network before mounting
        "rw"
        "noatime"
        # REMOVED: x-systemd.automount - causes namespace issues with early services
        # REMOVED: x-systemd.idle-timeout - pgBackRest needs stable mount
        # REMOVED: "intr" - Deprecated and ignored in NFSv4
        "x-systemd.mount-timeout=30s"
      ];
    };

    fileSystems."/mnt/nas-docs" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/docs";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"  # Unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"
      ];
    };

    # MIGRATED: Legacy backup-integration system disabled in favor of unified backup system
    # modules.services.backup-integration = {
    #   enable = true;
    #   autoDiscovery.enable = true;
    #   defaultRepository = "nas-primary";
    # };

    # ACTIVE: Unified backup system integration
    # Migrated from legacy backup-integration system

    modules.services.backup = {
      enable = true;

      repositories = {
        nas-primary = {
          url = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          primary = true;
          type = "local";
          # Consistent naming for Prometheus metrics
          repositoryName = "NFS";
          repositoryLocation = "nas-1";
        };
        r2-offsite = {
          url = "s3:https://21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
          passwordFile = config.sops.secrets."restic/password".path;
          environmentFile = config.sops.secrets."restic/r2-prod-env".path;
          primary = false;
          type = "s3";
          # Consistent naming for Prometheus metrics
          repositoryName = "R2";
          repositoryLocation = "offsite";
        };
      };

      # PostgreSQL backup (pgBackRest with dual-repo PITR)
      # Restic meta-backup DISABLED - redundant now that repo2 has WAL archiving
      # Both repo1 (NFS) and repo2 (R2) now support full Point-in-Time Recovery
      postgres = {
        enable = true;
        pgbackrest.enableOffsite = false;  # Disabled - repo2 now handles offsite PITR
        # pgbackrest.offsiteRepository = "r2-offsite";  # No longer needed
      };

      # Restic backup discovery and management
      restic.enable = true;

      # ZFS snapshot coordination (opt-in for services)
      snapshots.enable = true;

      # Enterprise monitoring and verification
      monitoring.enable = true;
      verification.enable = true;
    };

    # Forge-specific backup monitoring alerts
    # Standard Restic alerts are co-located with the backup service module
    # Only forge-specific or ZFS-related alerts belong here
    modules.alerting.rules = lib.mkIf config.modules.services.backup.enable {
      # High error count - Forge-specific log parsing metric
      # TODO: Consider moving this to the backup module if it becomes a standard metric
      "restic-backup-errors" = {
        type = "promql";
        alertname = "ResticBackupErrors";
        expr = "backup_errors_by_severity_total{severity=\"critical\"} > 0";
        for = "5m";
        severity = "high";
        labels = { service = "backup"; category = "restic"; };
        annotations = {
          summary = "Restic backup errors detected on {{ $labels.instance }}";
          description = "{{ $value }} critical backup errors. Check logs: /var/log/backup/";
        };
      };

      # Note: ZFS replication alerts moved to storage.nix for better cohesion
      # (replication configuration and monitoring are now co-located)

      # ZFS Holds Stale Detection (Restic cleanup monitoring)
      # Co-located with backup logic since it monitors backup tool behavior (Restic hold cleanup)
      "zfs-holds-stale" = {
        type = "promql";
        alertname = "ZFSHoldsStale";
        expr = ''
          count(zfs_hold_age_seconds > 21600) by (hostname) > 3
        '';
        for = "2h";
        severity = "medium";
        labels = { category = "backup"; service = "restic"; };
        annotations = {
          summary = "Stale ZFS holds detected on {{ $labels.hostname }}";
          description = "More than 3 ZFS holds on '{{ $labels.hostname }}' are older than 6 hours. This may indicate Restic backup cleanup issues.";
          command = "zfs holds -H | awk '{print $1, $2}' | sort";
        };
      };
    };
  };
}
