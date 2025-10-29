# ZFS Snapshot Management for Backup Consistency
#
# Provides opt-in ZFS snapshot coordination with Restic backups:
# - Services explicitly declare if they need snapshots via useSnapshots=true
# - Creates temporary snapshots before backup, removes after
# - Integrates with existing Sanoid for ongoing snapshot management
# - No coupling between services and centralized Sanoid config

{ config, lib, pkgs }:

let
  cfg = config.modules.services.backup;
  snapshotsCfg = cfg.snapshots or {};

  # Discover services that need snapshot-coordinated backups
  servicesNeedingSnapshots =
    let
      allServices = config.modules.services or {};
      resticJobs = cfg.restic.jobs or {};

      # Get all backup jobs (discovered + manual) that use snapshots
      jobsWithSnapshots = lib.filterAttrs (name: job:
        job.enable && job.useSnapshots && job.zfsDataset != null
      ) resticJobs;

      # Also check discovered service backups
      discoveredWithSnapshots = lib.filterAttrs (serviceName: service:
        (service.backup or null) != null &&
        (service.backup.enable or false) &&
        (service.backup.useSnapshots or false) &&
        (service.zfsDataset or null) != null
      ) allServices;

    in jobsWithSnapshots // (lib.mapAttrs' (serviceName: service: {
      name = "service-${serviceName}";
      value = {
        enable = true;
        zfsDataset = service.zfsDataset;
        useSnapshots = true;
      };
    }) discoveredWithSnapshots);

  # Create snapshot service for a backup job
  mkSnapshotService = jobName: jobConfig:
    let
      dataset = jobConfig.zfsDataset;
      snapshotName = "backup-${jobName}";
    in {
      "zfs-snapshot-${jobName}" = {
        description = "Create ZFS snapshot for ${jobName} backup";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;

          # Script to create snapshot
          ExecStart = pkgs.writeShellScript "create-snapshot-${jobName}" ''
            set -euo pipefail

            # Check if dataset exists
            if ! ${pkgs.zfs}/bin/zfs list "${dataset}" >/dev/null 2>&1; then
              echo "Dataset ${dataset} does not exist, skipping snapshot"
              exit 0
            fi

            # Create snapshot
            echo "Creating snapshot ${dataset}@${snapshotName}"
            ${pkgs.zfs}/bin/zfs snapshot "${dataset}@${snapshotName}"

            # Record snapshot creation time for monitoring
            echo "zfs_backup_snapshot_created{dataset=\"${dataset}\",snapshot=\"${snapshotName}\",job=\"${jobName}\",hostname=\"${config.networking.hostName}\"} $(date +%s)" \
              > /var/lib/node_exporter/textfile_collector/zfs_snapshot_${jobName}.prom
          '';

          # Script to cleanup snapshot
          ExecStop = pkgs.writeShellScript "cleanup-snapshot-${jobName}" ''
            set -euo pipefail

            # Remove snapshot if it exists
            if ${pkgs.zfs}/bin/zfs list -t snapshot "${dataset}@${snapshotName}" >/dev/null 2>&1; then
              echo "Removing snapshot ${dataset}@${snapshotName}"
              ${pkgs.zfs}/bin/zfs destroy "${dataset}@${snapshotName}"
            fi

            # Clean up metrics file
            rm -f /var/lib/node_exporter/textfile_collector/zfs_snapshot_${jobName}.prom
          '';

          # Timeout settings
          TimeoutStartSec = "60s";
          TimeoutStopSec = "60s";
        };

        # Ensure snapshot is cleaned up on failure
        unitConfig = {
          CollectMode = "inactive-or-failed";
        };
      };
    };

in {
  options.modules.services.backup.snapshots = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ZFS snapshot coordination for backups";
    };

    retentionPolicy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          keepBackupSnapshots = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Number of backup snapshots to keep (cleanup old ones)";
          };

          maxAge = lib.mkOption {
            type = lib.types.str;
            default = "24h";
            description = "Maximum age for backup snapshots before cleanup";
          };
        };
      };
      default = {};
      description = "Retention policy for backup snapshots";
    };
  };

  config = lib.mkIf (cfg.enable && snapshotsCfg.enable) {
    # Create snapshot services for jobs that need them
    systemd.services = lib.mkMerge (lib.mapAttrsToList mkSnapshotService servicesNeedingSnapshots);

    # Cleanup service for old backup snapshots
    systemd.services.zfs-backup-snapshot-cleanup = {
      description = "Cleanup old ZFS backup snapshots";
      serviceConfig = {
        Type = "oneshot";
        User = "root";  # ZFS operations require root

        ExecStart = pkgs.writeShellScript "cleanup-backup-snapshots" ''
          set -euo pipefail

          echo "Cleaning up old backup snapshots..."

          # Find all backup snapshots older than maxAge
          ${pkgs.zfs}/bin/zfs list -H -t snapshot -o name,creation \
            | grep '@backup-' \
            | while IFS=$'\t' read -r snapshot creation; do
              # Calculate age (simplified - just check if older than 1 day for now)
              snapshot_date=$(echo "$creation" | ${pkgs.coreutils}/bin/cut -d' ' -f1-3)
              if ${pkgs.coreutils}/bin/date -d "$snapshot_date + ${snapshotsCfg.retentionPolicy.maxAge}" '+%s' -lt $(${pkgs.coreutils}/bin/date '+%s') 2>/dev/null; then
                echo "Destroying old snapshot: $snapshot"
                ${pkgs.zfs}/bin/zfs destroy "$snapshot" || true
              fi
            done

          echo "Snapshot cleanup completed"
        '';
      };
    };

    # Timer for snapshot cleanup
    systemd.timers.zfs-backup-snapshot-cleanup = {
      description = "Timer for ZFS backup snapshot cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    # Ensure ZFS is available
    assertions = [
      {
        assertion = config.boot.supportedFilesystems ? "zfs" || config.services.zfs.enable;
        message = "ZFS snapshot coordination requires ZFS support to be enabled";
      }
    ];
  };
}
