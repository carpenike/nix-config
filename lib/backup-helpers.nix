# DEPRECATED: This file is no longer used in the backup system
#
# The backup system has been migrated to use Sanoid for ZFS snapshots
# and the main backup module at hosts/_modules/nixos/backup.nix handles
# all Restic backup orchestration with .zfs/snapshot path resolution.
#
# This file is kept for reference only and is not imported anywhere.
#
# Migration date: 2025-10-14
# See: hosts/_modules/nixos/backup.nix (lines 1691-1760) for current implementation
# See: hosts/_modules/nixos/storage/sanoid.nix for Sanoid configuration
#
# Return a function that takes pkgs and lib to avoid early evaluation
{ pkgs, lib }: {
  # Create a Restic backup job with proper systemd integration and security
  mkResticBackup =
    { name
    , paths
    , preBackupScript ? ""
    , postBackupScript ? ""
    , excludePatterns ? [ ]
    , tags ? [ name ]
    , resources ? {
        memory = "256M";
        memoryReservation = "128M";
        cpus = "0.5";
      }
    , user ? "restic-backup"
    , group ? "restic-backup"
    , environmentFile ? "/run/secrets/restic-${name}.env"
    , readConcurrency ? 2
    , compression ? "auto"
    , ...
    }: {
      # Only create systemd service - users/groups are created statically in backup.nix
      systemd.services."backup-${name}" = {
        description = "Restic backup for ${name}";
        wants = [ "backup.target" ];
        wantedBy = [ "backup.target" ]; # Fix: Actually start when backup.target is started
        after = [ "network-online.target" ];

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
          MemoryLow = resources.memoryReservation; # Protection from reclamation
          CPUQuota = lib.strings.removeSuffix ".0" (toString (lib.strings.toFloat resources.cpus * 100)) + "%";

          # Environment and secrets
          EnvironmentFile = environmentFile;

          # Failure handling
          Restart = "on-failure";
          RestartSec = "300";
          SuccessExitStatus = "1"; # Allow partial backups (Restic exit code 1)
        };

        script =
          let
            excludeArgs = lib.concatMapStringsSep " " (pattern: "--exclude '${pattern}'") excludePatterns;
            tagArgs = lib.concatMapStringsSep " " (tag: "--tag '${tag}'") tags;
            pathArgs = lib.concatStringsSep " " (path: "'${path}'") paths;
          in
          ''
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

  # Create monitoring notifications
  mkBackupMonitoring =
    { healthchecksUrl ? ""
    , ntfyTopic ? ""
    , ...
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
