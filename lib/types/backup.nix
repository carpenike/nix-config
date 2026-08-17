# Backup integration type definition
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized backup integration submodule
  # Stateful services should use this type for consistent backup policies
  backupSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "backups for this service";

      repository = mkOption {
        type = types.str;
        description = "Backup repository identifier";
        example = "primary";
      };

      paths = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Paths to backup (defaults to service dataDir if empty)";
        example = [ "/var/lib/service" "/etc/service" ];
      };

      frequency = mkOption {
        type = types.enum [ "hourly" "daily" "weekly" ];
        default = "daily";
        description = "Backup frequency";
      };

      # NOTE: there is deliberately no per-service `retention` option here.
      #
      # One existed and was never wired to anything: the auto-discovery in
      # modules/nixos/services/backup/default.nix does not map it, and the
      # `_internal.allJobs` submodule has no such field, so restic's
      # forget/prune (modules/nixos/services/backup/restic.nix) has only ever
      # applied `modules.services.backup.globalSettings.retention`. Forty-six
      # services on forge carried a declared 7/4/6 that did nothing.
      #
      # It was removed rather than implemented on purpose. The declared values
      # were the shared default everywhere -- no host ever customised them --
      # and the effective global policy is strictly more generous (14 daily /
      # 8 weekly / 6 monthly / 2 yearly). Honouring the per-service values
      # would therefore have *shortened* retention on every one of those
      # services and made the next `restic forget` prune snapshots that exist
      # today. A dead option is worth deleting; it is not worth a silent
      # destructive change.
      #
      # Set retention on `modules.services.backup.globalSettings.retention`.
      # If per-service retention is ever genuinely wanted, it has to be
      # threaded through discovery, the allJobs submodule, and the forget
      # command together -- and rolled out knowing it deletes snapshots.

      preBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run before backup (e.g., database dump)";
      };

      postBackupScript = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Script to run after backup";
      };

      excludePatterns = mkOption {
        type = types.listOf types.str;
        default = [
          "**/.cache"
          "**/cache"
          "**/*.tmp"
          "**/*.log"
        ];
        description = "Patterns to exclude from backup";
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Tags to apply to backup snapshots";
        example = [ "database" "production" "daily" ];
      };

      useSnapshots = mkOption {
        type = types.bool;
        default = false;
        description = "Use ZFS snapshots for consistent backups";
      };

      zfsDataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ZFS dataset for snapshot-based backups";
        example = "tank/services/myservice";
      };

      resources = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            memory = mkOption {
              type = types.str;
              default = "512M";
              description = "Maximum memory limit for backup process (systemd MemoryMax)";
              example = "1G";
            };

            memoryReservation = mkOption {
              type = types.str;
              default = "256M";
              description = "Memory reservation for backup process (systemd MemoryLow)";
              example = "512M";
            };

            cpus = mkOption {
              type = types.str;
              default = "1.0";
              description = "CPU quota for backup process (fraction of one core)";
              example = "2.0";
            };
          };
        });
        default = null;
        description = "Resource limits for the backup job. If null, uses global defaults from backup.performance.resources";
        example = {
          memory = "1G";
          memoryReservation = "512M";
          cpus = "2.0";
        };
      };
    };
  };
}
