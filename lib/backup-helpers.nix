# Return a function that takes pkgs and lib to avoid early evaluation
{ pkgs, lib }: {
    # Create a Restic backup job with proper systemd integration and security
    mkResticBackup = {
      name,
      paths,
      repository,
      preBackupScript ? "",
      postBackupScript ? "",
      excludePatterns ? [],
      tags ? [name],
      resources ? {
        memory = "256m";
        memoryReservation = "128m";
        cpus = "0.5";
      },
      user ? "restic-backup",
      group ? "restic-backup",
      environmentFile ? "/run/secrets/restic-${name}.env",
      useZfsSnapshot ? true,
      readConcurrency ? 2,
      compression ? "auto",
      ...
    }: {
      # Only create systemd service - users/groups are created statically in backup.nix
      systemd.services."backup-${name}" = {
          description = "Restic backup for ${name}";
          wants = [ "backup.target" ];
          wantedBy = [ "backup.target" ];  # Fix: Actually start when backup.target is started
          after = [ "network-online.target" ] ++ lib.optional useZfsSnapshot "zfs-snapshot.service";
          requires = lib.optional useZfsSnapshot "zfs-snapshot.service";  # Fix: Make ZFS dependency conditional

          serviceConfig = {
            Type = "oneshot";
            User = user;
            Group = group;

            # Security hardening (O3 recommendations)
            DynamicUser = lib.mkDefault (user != "root");
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            MemoryDenyWriteExecute = true;

            # Resource limits (prevent backup impact on services)
            Slice = "backup.slice";
            IOSchedulingClass = "idle";
            CPUSchedulingPolicy = "idle";

            # Apply per-job resource limits from options
            MemoryMax = resources.memory;
            MemoryLow = resources.memoryReservation;  # Protection from reclamation
            CPUQuota = lib.strings.removeSuffix ".0" (toString (lib.strings.toFloat resources.cpus * 100)) + "%";

            # Environment and secrets
            EnvironmentFile = environmentFile;

            # Failure handling
            Restart = "on-failure";
            RestartSec = "300";
            SuccessExitStatus = "1"; # Allow partial backups (Restic exit code 1)
          };

          script = let
            excludeArgs = lib.concatMapStringsSep " " (pattern: "--exclude '${pattern}'") excludePatterns;
            tagArgs = lib.concatMapStringsSep " " (tag: "--tag '${tag}'") tags;
            pathArgs = lib.concatStringsSep " " (path: "'${path}'") paths;
          in ''
            set -euo pipefail

            # Pre-backup tasks
            ${preBackupScript}

            # Initialize repository if it doesn't exist
            ${pkgs.restic}/bin/restic snapshots &>/dev/null || ${pkgs.restic}/bin/restic init

            # Perform backup from ZFS snapshot mount point
            echo "Starting backup for ${name}..."
            ${pkgs.restic}/bin/restic backup \
              ${pathArgs} \
              ${excludeArgs} \
              ${tagArgs} \
              --verbose \
              --read-concurrency ${toString readConcurrency} \
              --compression ${compression}

            # Post-backup tasks
            ${postBackupScript}

            echo "Backup completed successfully for ${name}"
          '';

          # Success/failure notifications
          onSuccess = [ "backup-notify-success@${name}.service" ];
          onFailure = [ "backup-notify-failure@${name}.service" ];
        };
      };

    # Create ZFS snapshot with proper naming and retention
    mkZfsSnapshot = {
      pool,
      datasets ? [""],
      retention ? {
        daily = 7;
        weekly = 4;
        monthly = 3;
      },
      ...
    }: {
      systemd.services.zfs-snapshot = {
        description = "Create ZFS snapshots for backup";
        before = [ "backup.target" ];
        wants = [ "pre-backup-tasks.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
        };

        script = let
          timestamp = "$(date +%Y-%m-%d_%H-%M-%S)";
          snapshotName = "backup-${timestamp}";
        in ''
          set -euo pipefail

          echo "Creating ZFS snapshots..."

          # Create snapshots for each dataset
          ${lib.concatMapStringsSep "\n" (dataset:
            let fullPath = if dataset == "" then pool else "${pool}/${dataset}";
            in ''
              echo "Snapshotting ${fullPath}..."
              ${pkgs.zfs}/bin/zfs snapshot ${fullPath}@${snapshotName}
            ''
          ) datasets}

          # Mount latest snapshot for backup access
          mkdir -p /mnt/backup-snapshot
          ${pkgs.zfs}/bin/zfs clone ${pool}@${snapshotName} ${pool}/backup-temp
          ${pkgs.util-linux}/bin/mount -t zfs ${pool}/backup-temp /mnt/backup-snapshot

          echo "ZFS snapshots created and mounted at /mnt/backup-snapshot"
        '';
      };

      # Cleanup old snapshots based on retention policy
      systemd.services.zfs-snapshot-cleanup = {
        description = "Clean up old ZFS backup snapshots";
        after = [ "backup.target" ];
        wants = [ "post-backup-tasks.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
        };

        script = ''
          set -euo pipefail

          echo "Cleaning up old snapshots..."

          # Unmount and destroy temporary clone
          if mountpoint -q /mnt/backup-snapshot; then
            ${pkgs.util-linux}/bin/umount /mnt/backup-snapshot
          fi

          if ${pkgs.zfs}/bin/zfs list ${pool}/backup-temp &>/dev/null; then
            ${pkgs.zfs}/bin/zfs destroy ${pool}/backup-temp
          fi

          # Clean up old backup snapshots based on retention policy
          ${lib.concatMapStringsSep "\n" (dataset:
            let fullPath = if dataset == "" then pool else "${pool}/${dataset}";
            in ''
              # Keep daily snapshots for ${toString retention.daily} days
              ${pkgs.zfs}/bin/zfs list -H -o name -t snapshot ${fullPath} | \
                grep '@backup-' | sort -r | tail -n +$((${toString retention.daily} + 1)) | \
                head -n -${toString (retention.weekly + retention.monthly)} | \
                xargs -r -n1 ${pkgs.zfs}/bin/zfs destroy
            ''
          ) datasets}

          echo "Snapshot cleanup completed"
        '';
      };
    };

    # Create monitoring notifications
    mkBackupMonitoring = {
      healthchecksUrl ? "",
      ntfyTopic ? "",
      ...
    }: {
      # Success notification service template
      systemd.services."backup-notify-success@" = {
        description = "Notify backup success for %i";

        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          PrivateNetwork = false;
        };

        script = ''
          set -euo pipefail

          SERVICE_NAME="%i"

          # Notify Healthchecks.io
          ${lib.optionalString (healthchecksUrl != "") ''
            echo "Notifying Healthchecks.io of success for $SERVICE_NAME"
            ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 "${healthchecksUrl}" || true
          ''}

          # Notify via ntfy
          ${lib.optionalString (ntfyTopic != "") ''
            echo "Sending ntfy notification for $SERVICE_NAME"
            ${pkgs.curl}/bin/curl -fsS -m 10 \
              -H "Title: Backup Success" \
              -H "Tags: white_check_mark,backup" \
              -d "Backup completed successfully for $SERVICE_NAME" \
              "${ntfyTopic}" || true
          ''}
        '';
      };

      # Failure notification service template
      systemd.services."backup-notify-failure@" = {
        description = "Notify backup failure for %i";

        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          PrivateNetwork = false;
        };

        script = ''
          set -euo pipefail

          SERVICE_NAME="%i"

          # Notify via ntfy with failure details
          ${lib.optionalString (ntfyTopic != "") ''
            echo "Sending failure notification for $SERVICE_NAME"
            ${pkgs.curl}/bin/curl -fsS -m 10 \
              -H "Title: Backup Failed" \
              -H "Tags: x,backup,warning" \
              -H "Priority: high" \
              -d "Backup failed for $SERVICE_NAME. Check systemd logs: journalctl -u backup-$SERVICE_NAME" \
              "${ntfyTopic}" || true
          ''}
        '';
      };
    };
}
