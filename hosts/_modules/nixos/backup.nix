{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{

  options.modules.backup = {
    enable = mkEnableOption "comprehensive backup system";

    zfs = {
      enable = mkEnableOption "ZFS snapshot integration";

      pool = mkOption {
        type = types.str;
        default = "rpool";
        description = "ZFS pool to snapshot";
      };

      datasets = mkOption {
        type = types.listOf types.str;
        default = [""];
        description = "Datasets to snapshot (empty string for root dataset)";
      };

      retention = mkOption {
        type = types.submodule {
          options = {
            daily = mkOption {
              type = types.int;
              default = 7;
              description = "Number of daily snapshots to keep";
            };
            weekly = mkOption {
              type = types.int;
              default = 4;
              description = "Number of weekly snapshots to keep";
            };
            monthly = mkOption {
              type = types.int;
              default = 3;
              description = "Number of monthly snapshots to keep";
            };
          };
        };
        default = {};
        description = "Snapshot retention policy";
      };
    };

    restic = {
      enable = mkEnableOption "Restic backup integration";

      globalSettings = {
        compression = mkOption {
          type = types.enum ["auto" "off" "max"];
          default = "auto";
          description = "Global compression setting for all backup jobs";
        };

        readConcurrency = mkOption {
          type = types.int;
          default = 2;
          description = "Number of concurrent read operations";
        };

        retention = mkOption {
          type = types.submodule {
            options = {
              daily = mkOption {
                type = types.int;
                default = 14;
                description = "Number of daily backups to keep";
              };
              weekly = mkOption {
                type = types.int;
                default = 8;
                description = "Number of weekly backups to keep";
              };
              monthly = mkOption {
                type = types.int;
                default = 6;
                description = "Number of monthly backups to keep";
              };
              yearly = mkOption {
                type = types.int;
                default = 2;
                description = "Number of yearly backups to keep";
              };
            };
          };
          default = {};
          description = "Global retention policy for Restic backups";
        };
      };

      repositories = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Repository URL (local path or cloud endpoint)";
              example = "b2:bucket-name:/path or /mnt/nas/backups";
            };

            passwordFile = mkOption {
              type = types.path;
              description = ''
                Path to file containing repository password.
                WARNING: If this is a plain file, it will be world-readable in the Nix store.
                Use a path from a secrets tool like sops, e.g. `sops.secrets.restic-password.path`.
              '';
            };

            environmentFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to environment file with cloud credentials";
            };

            primary = mkOption {
              type = types.bool;
              default = false;
              description = "Whether this is the primary repository";
            };
          };
        });
        default = {};
        description = "Restic repositories configuration";
      };

      jobs = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            enable = mkEnableOption "this backup job";

            paths = mkOption {
              type = types.listOf types.str;
              description = "Paths to backup (will be prefixed with /mnt/backup-snapshot if ZFS enabled)";
            };

            excludePatterns = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Patterns to exclude from backup";
            };

            repository = mkOption {
              type = types.str;
              description = "Repository name to use for this job";
            };

            tags = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Additional tags for this backup job";
            };

            preBackupScript = mkOption {
              type = types.lines;
              default = "";
              description = "Script to run before backup";
            };

            postBackupScript = mkOption {
              type = types.lines;
              default = "";
              description = "Script to run after backup";
            };

            resources = mkOption {
              type = types.submodule {
                options = {
                  memory = mkOption {
                    type = types.str;
                    default = "256m";
                    description = "Memory limit for backup process";
                  };
                  memoryReservation = mkOption {
                    type = types.str;
                    default = "128m";
                    description = "Memory reservation for backup process";
                  };
                  cpus = mkOption {
                    type = types.str;
                    default = "0.5";
                    description = "CPU limit for backup process";
                  };
                };
              };
              default = {};
              description = "Resource limits for this backup job";
            };

          };
        });
        default = {};
        description = "Backup job configurations";
      };
    };

    monitoring = {
      enable = mkEnableOption "backup monitoring and notifications";

      healthchecks = {
        enable = mkEnableOption "Healthchecks.io monitoring";

        baseUrl = mkOption {
          type = types.str;
          default = "https://hc-ping.com";
          description = "Healthchecks.io base URL";
        };

        uuidFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to file containing Healthchecks.io UUID";
        };
      };

      ntfy = {
        enable = mkEnableOption "ntfy.sh notifications";

        topic = mkOption {
          type = types.str;
          default = "";
          description = "ntfy.sh topic URL for notifications";
        };
      };
    };

    schedule = mkOption {
      type = types.str;
      default = "02:00";
      description = "Time to run backups (24-hour format)";
    };
  };

  config = let
    cfg = config.modules.backup;
  in mkIf cfg.enable {
    # Ensure required packages are available
    environment.systemPackages = with pkgs; [
      restic
      zfs
      curl
    ];

    # ZFS snapshot service (simplified)
    systemd.services.zfs-snapshot = mkIf cfg.zfs.enable {
      description = "Create ZFS snapshot for backup";
      path = with pkgs; [ zfs ];
      script = ''
        zfs destroy ${cfg.zfs.pool}@backup-snapshot || true
        zfs snapshot ${cfg.zfs.pool}@backup-snapshot
        mkdir -p /mnt/backup-snapshot
        mount -t zfs ${cfg.zfs.pool}@backup-snapshot /mnt/backup-snapshot
      '';
      postStop = ''
        umount /mnt/backup-snapshot || true
        zfs destroy ${cfg.zfs.pool}@backup-snapshot || true
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    # Use built-in NixOS restic service - truxnell's approach
    services.restic.backups = mkMerge (mapAttrsToList (jobName: jobConfig:
      mkIf jobConfig.enable (
        let
          repo = cfg.restic.repositories.${jobConfig.repository};
          actualPaths = if cfg.zfs.enable
            then map (path: "/mnt/backup-snapshot${path}") jobConfig.paths
            else jobConfig.paths;
        in {
          "${jobName}" = {
            paths = actualPaths;
            repository = repo.url;
            passwordFile = repo.passwordFile;
            environmentFile = repo.environmentFile;
            exclude = jobConfig.excludePatterns;
            initialize = true;
            timerConfig = {
              OnCalendar = cfg.schedule;
              Persistent = true;
              RandomizedDelaySec = "15m";
            };
            pruneOpts = [
              "--keep-daily ${toString cfg.restic.globalSettings.retention.daily}"
              "--keep-weekly ${toString cfg.restic.globalSettings.retention.weekly}"
              "--keep-monthly ${toString cfg.restic.globalSettings.retention.monthly}"
              "--keep-yearly ${toString cfg.restic.globalSettings.retention.yearly}"
            ];
            backupPrepareCommand = mkIf cfg.zfs.enable ''
              ${pkgs.systemd}/bin/systemctl start zfs-snapshot.service
            '';
            backupCleanupCommand = mkIf cfg.zfs.enable ''
              ${pkgs.systemd}/bin/systemctl stop zfs-snapshot.service
            '';
          };
        })
    ) cfg.restic.jobs);

    # Validation assertions
    assertions = [
      {
        assertion = cfg.zfs.enable -> config.boot.supportedFilesystems.zfs or false;
        message = "ZFS support must be enabled in boot.supportedFilesystems when using ZFS backup integration";
      }
      {
        assertion = cfg.restic.enable -> (cfg.restic.repositories != {});
        message = "At least one Restic repository must be configured when Restic backup is enabled";
      }
      {
        assertion = cfg.monitoring.healthchecks.enable -> (cfg.monitoring.healthchecks.uuidFile != null);
        message = "Healthchecks.io UUID file must be specified when Healthchecks monitoring is enabled";
      }
    ] ++ (mapAttrsToList (jobName: jobConfig: {
      assertion = jobConfig.enable -> (hasAttr jobConfig.repository cfg.restic.repositories);
      message = "Backup job '${jobName}' references unknown repository '${jobConfig.repository}'";
    }) cfg.restic.jobs);
  };
}
