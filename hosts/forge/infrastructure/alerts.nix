{ ... }:

{
  # Backup and snapshot health monitoring alerts
  # These alerts monitor backup operations that span multiple systems/datasets
  #
  # Alert organization following contribution pattern:
  # - Core system health → core/monitoring.nix
  # - ZFS storage alerts → infrastructure/storage.nix
  # - Container health → infrastructure/containerization.nix
  # - Service-specific → services/*.nix
  # - Backup/snapshot age (cross-cutting) → this file

  modules.alerting = {
    # Enable dead man's switch via Healthchecks.io
    receivers.healthchecks.urlSecret = "monitoring/healthchecks-url";

    rules = {
      # ZFS snapshot age too old - Sanoid not running
      "zfs-snapshot-too-old" = {
        type = "promql";
        alertname = "ZFSSnapshotTooOld";
        expr = ''
          zfs_latest_snapshot_age_seconds > 86400
        '';
        for = "30m";
        severity = "high";
        labels = { service = "backup"; category = "zfs"; };
        annotations = {
          summary = "ZFS snapshot for {{ $labels.dataset }} is over 24 hours old on {{ $labels.hostname }}";
          description = "Latest snapshot age: {{ $value | humanizeDuration }}. Sanoid may not be running. Check: systemctl status sanoid.service";
          command = "systemctl status sanoid.service && journalctl -u sanoid.service --since '24h'";
        };
      };

      # ZFS snapshot critically old - backup data at risk
      "zfs-snapshot-critical" = {
        type = "promql";
        alertname = "ZFSSnapshotCritical";
        expr = ''
          zfs_latest_snapshot_age_seconds > 172800
        '';
        for = "1h";
        severity = "critical";
        labels = { service = "backup"; category = "zfs"; };
        annotations = {
          summary = "ZFS snapshot for {{ $labels.dataset }} is over 48 hours old on {{ $labels.hostname }}";
          description = "Latest snapshot age: {{ $value | humanizeDuration }}. CRITICAL: Backup data is stale. Immediate investigation required.";
          command = "systemctl status sanoid.service && zfs list -t snapshot {{ $labels.dataset }}";
        };
      };

      # Stale ZFS holds detected
      "zfs-holds-stale" = {
        type = "promql";
        alertname = "ZFSHoldsStale";
        expr = ''
          count(zfs_hold_age_seconds > 21600) by (hostname) > 3
        '';
        for = "2h";
        severity = "medium";
        labels = { service = "backup"; category = "zfs"; };
        annotations = {
          summary = "Multiple stale ZFS holds detected on {{ $labels.hostname }}";
          description = "{{ $value }} holds are older than 6 hours. Backup jobs may have failed. Check: systemctl status restic-zfs-hold-gc.service";
          command = "zfs holds -rH | grep restic- && systemctl status restic-zfs-hold-gc.service";
        };
      };

      # NOTE: Restic backup alerts (restic-backup-failed, restic-backup-stale) are defined
      # in hosts/_modules/nixos/services/backup/monitoring.nix alongside the backup module
    };
  };
}
