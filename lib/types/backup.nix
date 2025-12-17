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

      retention = mkOption {
        type = types.submodule {
          options = {
            daily = mkOption {
              type = types.int;
              default = 7;
              description = "Number of daily backups to retain";
            };

            weekly = mkOption {
              type = types.int;
              default = 4;
              description = "Number of weekly backups to retain";
            };

            monthly = mkOption {
              type = types.int;
              default = 6;
              description = "Number of monthly backups to retain";
            };
          };
        };
        default = { };
        description = "Backup retention policy";
      };

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
    };
  };
}
