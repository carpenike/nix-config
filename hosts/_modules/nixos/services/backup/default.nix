# Unified Backup Management Module
#
# This module provides a comprehensive backup solution with:
# - Opt-in ZFS snapshot management via Sanoid
# - Restic backups with enterprise monitoring
# - PostgreSQL-specific pgBackRest integration
# - Automated service discovery
# - Prometheus metrics integration
# - Verification and restore testing framework
#
# Design Principles:
# - Opt-in snapshots: Services explicitly declare if they need ZFS snapshots
# - Unified monitoring: All backup metrics flow through textfile collector
# - Enterprise verification: Automated integrity checks and restore testing
# - Direct implementation: Simple config → working system (homelab appropriate)

{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.backup;

  # Centralized job calculation for both restic and snapshots modules
  # Discover services with backup configurations
  discoverServiceBackups =
    let
      allServices = config.modules.services or {};
      servicesWithBackup = lib.filterAttrs (name: service:
        (service.backup or null) != null &&
        (service.backup.enable or false) &&
        (service.enable or false)  # Only backup services that are actually enabled
      ) allServices;
    in
      lib.mapAttrs' (serviceName: service: {
        name = "service-${serviceName}";
        value = {
          enable = true;
          repository = service.backup.repository or cfg.serviceDiscovery.defaultRepository;
          paths = service.backup.paths or [
            (service.dataDir or "/var/lib/${serviceName}")
          ];
          tags = [ serviceName ] ++ (service.backup.tags or []);
          excludePatterns = (service.backup.excludePatterns or []) ++ cfg.serviceDiscovery.globalExcludes;
          preBackupScript = if (service.backup.preBackupScript or null) != null then service.backup.preBackupScript else "";
          postBackupScript = if (service.backup.postBackupScript or null) != null then service.backup.postBackupScript else "";
          frequency = service.backup.frequency or "daily";
          resources = service.backup.resources or cfg.performance.resources;

          # ZFS snapshot integration
          useSnapshots = service.backup.useSnapshots or false;
          zfsDataset = service.backup.zfsDataset or null;
        };
      }) servicesWithBackup;

  # Combine discovered jobs with manual jobs - this is the single source of truth
  allJobs = discoverServiceBackups // (cfg.restic.jobs or {});

  # Import submodules
  resticModule = import ./restic.nix { inherit config lib pkgs; };
  postgresModule = import ./postgres.nix { inherit config lib pkgs; };
  snapshotsModule = import ./snapshots.nix { inherit config lib pkgs; };
  monitoringModule = import ./monitoring.nix { inherit config lib pkgs; };
  verificationModule = import ./verification.nix { inherit config lib pkgs; };
in
{
  imports = [
    ./restic.nix
    ./postgres.nix
    ./snapshots.nix
    ./monitoring.nix
    ./verification.nix
  ];

  options.modules.services.backup = {
    enable = lib.mkEnableOption "unified backup management system";

    # Internal option to share consolidated jobs between submodules
    _internal = {
      allJobs = lib.mkOption {
        internal = true;
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            enable = lib.mkOption { type = lib.types.bool; default = true; };
            repository = lib.mkOption { type = lib.types.str; };
            paths = lib.mkOption { type = lib.types.listOf lib.types.str; };
            tags = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
            excludePatterns = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
            preBackupScript = lib.mkOption { type = lib.types.str; default = ""; };
            postBackupScript = lib.mkOption { type = lib.types.str; default = ""; };
            frequency = lib.mkOption { type = lib.types.str; default = "daily"; };
            resources = lib.mkOption { type = lib.types.attrs; default = {}; };
            useSnapshots = lib.mkOption { type = lib.types.bool; default = false; };
            zfsDataset = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          };
        });
        default = {};
        description = "Internal consolidated backup jobs from service discovery and manual configuration";
      };
    };

    # Core backup repositories configuration
    repositories = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Repository URL (local path or S3/B2 endpoint)";
          };

          passwordFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to repository password file";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Environment file for cloud credentials";
          };

          primary = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this is the primary repository";
          };

          type = lib.mkOption {
            type = lib.types.enum [ "local" "s3" "b2" "rest" ];
            default = "local";
            description = "Repository type for optimization";
          };
        };
      });
      default = {};
      description = "Backup repositories configuration";
    };

    # Global backup settings
    globalSettings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          compression = lib.mkOption {
            type = lib.types.enum [ "auto" "off" "lz4" "zstd" ];
            default = "auto";
            description = "Default compression algorithm";
          };

          retention = lib.mkOption {
            type = lib.types.submodule {
              options = {
                daily = lib.mkOption {
                  type = lib.types.int;
                  default = 14;
                  description = "Daily snapshots to keep";
                };
                weekly = lib.mkOption {
                  type = lib.types.int;
                  default = 8;
                  description = "Weekly snapshots to keep";
                };
                monthly = lib.mkOption {
                  type = lib.types.int;
                  default = 6;
                  description = "Monthly snapshots to keep";
                };
                yearly = lib.mkOption {
                  type = lib.types.int;
                  default = 2;
                  description = "Yearly snapshots to keep";
                };
              };
            };
            default = {};
            description = "Default retention policy";
          };

          readConcurrency = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "Default read concurrency for backups";
          };
        };
      };
      default = {};
      description = "Global backup settings";
    };

    # Service discovery configuration
    serviceDiscovery = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable automatic service backup discovery";
          };

          defaultRepository = lib.mkOption {
            type = lib.types.str;
            default = "nas-primary";
            description = "Default repository for discovered services";
          };

          globalExcludes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "**/.cache"
              "**/cache"
              "**/*.tmp"
              "**/*.log"
              "**/core"
              "**/*.pid"
              "**/lost+found"
              "**/.zfs"
            ];
            description = "Global exclude patterns for all service backups";
          };
        };
      };
      default = {};
      description = "Service discovery configuration";
    };

    # Schedule configuration
    schedule = lib.mkOption {
      type = lib.types.submodule {
        options = {
          backups = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            description = "Backup schedule (systemd timer format)";
          };

          verification = lib.mkOption {
            type = lib.types.str;
            default = "weekly";
            description = "Repository verification schedule";
          };

          restoreTesting = lib.mkOption {
            type = lib.types.str;
            default = "monthly";
            description = "Restore testing schedule";
          };
        };
      };
      default = {};
      description = "Backup scheduling configuration";
    };

    # Performance settings
    performance = lib.mkOption {
      type = lib.types.submodule {
        options = {
          cacheDir = lib.mkOption {
            type = lib.types.path;
            default = "/var/cache/restic";
            description = "Restic cache directory";
          };

          cacheSizeLimit = lib.mkOption {
            type = lib.types.str;
            default = "5G";
            description = "Maximum cache size";
          };

          ioScheduling = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Enable I/O scheduling for backup jobs";
                };

                ioClass = lib.mkOption {
                  type = lib.types.enum [ "idle" "best-effort" "rt" ];
                  default = "idle";
                  description = "I/O scheduling class";
                };

                priority = lib.mkOption {
                  type = lib.types.int;
                  default = 7;
                  description = "I/O priority (0-7, 7 = lowest)";
                };
              };
            };
            default = {};
            description = "I/O scheduling configuration";
          };

          resources = lib.mkOption {
            type = lib.types.submodule {
              options = {
                memory = lib.mkOption {
                  type = lib.types.str;
                  default = "512M";
                  description = "Default memory limit for backup jobs";
                };

                memoryReservation = lib.mkOption {
                  type = lib.types.str;
                  default = "256M";
                  description = "Default memory reservation";
                };

                cpus = lib.mkOption {
                  type = lib.types.str;
                  default = "1.0";
                  description = "Default CPU limit";
                };
              };
            };
            default = {};
            description = "Default resource limits";
          };
        };
      };
      default = {};
      description = "Performance and resource configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Populate the internal consolidated jobs option
    modules.services.backup._internal.allJobs = allJobs;

    # Ensure backup user and group exist
    users.users.restic-backup = {
      isSystemUser = true;
      group = "restic-backup";
      description = "Restic backup service user";
      # Add to service groups to access their data directories
      extraGroups = [
        "grafana" "loki" "plex" "sonarr" "dispatcharr"
        "promtail" "observability" "postgres"
      ];
    };

    users.groups.restic-backup = {};

    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d ${cfg.performance.cacheDir} 0750 restic-backup restic-backup -"
      "d /var/log/backup 0755 root root -"
      "d /var/lib/node_exporter/textfile_collector 0755 root root -"
      "d /tmp/restore-tests 0750 restic-backup restic-backup -"
    ];

    # Validation assertions
    assertions = [
      {
        assertion = cfg.repositories != {};
        message = "At least one backup repository must be configured";
      }
      {
        assertion = lib.length (lib.filter (repo: repo.primary) (lib.attrValues cfg.repositories)) <= 1;
        message = "Only one repository can be marked as primary";
      }
    ];
  };
}
