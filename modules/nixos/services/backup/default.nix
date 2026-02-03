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
      allServices = config.modules.services or { };
      servicesWithBackup = lib.filterAttrs
        (_name: service:
          (service.backup or null) != null &&
          (service.backup.enable or false) &&
          (service.enable or false)  # Only backup services that are actually enabled
        )
        allServices;
    in
    lib.mapAttrs'
      (serviceName: service: {
        name = "service-${serviceName}";
        value = {
          enable = true;
          repository = service.backup.repository or cfg.serviceDiscovery.defaultRepository;
          paths =
            if (service.backup.paths or [ ]) != [ ]
            then service.backup.paths
            else [ (service.dataDir or "/var/lib/${serviceName}") ];
          tags = [ serviceName ] ++ (service.backup.tags or [ ]);
          excludePatterns = (service.backup.excludePatterns or [ ]) ++ cfg.serviceDiscovery.globalExcludes;
          preBackupScript = if (service.backup.preBackupScript or null) != null then service.backup.preBackupScript else "";
          postBackupScript = if (service.backup.postBackupScript or null) != null then service.backup.postBackupScript else "";
          frequency = service.backup.frequency or "daily";
          # Handle null resources properly - use global defaults if null or not set
          resources =
            let res = service.backup.resources or null;
            in if res != null then res else cfg.performance.resources;

          # ZFS snapshot integration
          useSnapshots = service.backup.useSnapshots or false;
          zfsDataset = service.backup.zfsDataset or null;
        };
      })
      servicesWithBackup;

  # Combine discovered jobs with manual jobs - this is the single source of truth
  allJobs = discoverServiceBackups // (cfg.restic.jobs or { });

  # Submodules are imported below
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
            tags = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            excludePatterns = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            preBackupScript = lib.mkOption { type = lib.types.str; default = ""; };
            postBackupScript = lib.mkOption { type = lib.types.str; default = ""; };
            frequency = lib.mkOption { type = lib.types.str; default = "daily"; };
            resources = lib.mkOption { type = lib.types.attrs; default = { }; };
            useSnapshots = lib.mkOption { type = lib.types.bool; default = false; };
            zfsDataset = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          };
        });
        default = { };
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

          repositoryName = lib.mkOption {
            type = lib.types.str;
            default = "NFS";
            description = "Friendly name for the repository type (e.g., 'NFS', 'R2'). Used in Prometheus metrics for consistent naming across backup systems.";
          };

          repositoryLocation = lib.mkOption {
            type = lib.types.str;
            default = "nas-1";
            description = "Friendly location identifier (e.g., 'nas-1', 'offsite'). Used in Prometheus metrics for consistent naming across backup systems.";
          };

          pruneSchedule = lib.mkOption {
            type = lib.types.str;
            default = "weekly";
            description = "Systemd calendar expression for repository prune job. Set to \"\" to disable.";
          };
        };
      });
      default = { };
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
            default = { };
            description = "Default retention policy";
          };

          readConcurrency = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "Default read concurrency for backups";
          };
        };
      };
      default = { };
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
              ".zfs" # Exclude .zfs at any level (critical for snapshot-based backups)
              "**/.zfs" # Also exclude nested .zfs directories
            ];
            description = "Global exclude patterns for all service backups";
          };
        };
      };
      default = { };
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
      default = { };
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
            default = { };
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
            default = { };
            description = "Default resource limits";
          };
        };
      };
      default = { };
      description = "Performance and resource configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Populate the internal consolidated jobs option
    modules.services.backup._internal.allJobs = allJobs;

    # Create repository initialization services
    # These run once on boot and ensure repositories are initialized before backup jobs
    systemd.services = lib.mkMerge [
      # Repository initialization services (one per repository)
      (lib.mkMerge (lib.mapAttrsToList
        (repoName: repoConfig: {
          "restic-init-${repoName}" = {
            description = "Initialize Restic repository ${repoName} at ${repoConfig.url}";

            # For NFS repositories, depend on the automount being available (not the mount directly)
            # Use systemd path escaping (systemd-escape --path)
            after = lib.optionals (repoConfig.type == "local" && lib.hasPrefix "/mnt/" repoConfig.url) [
              (lib.replaceStrings [ "/" ] [ "-" ] (lib.replaceStrings [ "-" ] [ "\\x2d" ] (lib.removePrefix "/" repoConfig.url)) + ".automount")
            ] ++ [ "network-online.target" ];
            requires = lib.optionals (repoConfig.type == "local" && lib.hasPrefix "/mnt/" repoConfig.url) [
              (lib.replaceStrings [ "/" ] [ "-" ] (lib.replaceStrings [ "-" ] [ "\\x2d" ] (lib.removePrefix "/" repoConfig.url)) + ".automount")
            ] ++ [ "network-online.target" ];

            # Start on boot (before backup jobs)
            wantedBy = [ "multi-user.target" ];

            # Unit-level condition: only run for local repositories if config doesn't exist
            unitConfig = lib.mkIf (repoConfig.type == "local") {
              ConditionPathExists = "!${repoConfig.url}/config";
            };

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true; # Critical for dependency tracking

              # Security
              User = "restic-backup";
              Group = "restic-backup";
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;

              # Environment
              Environment = [
                "RESTIC_REPOSITORY=${repoConfig.url}"
                "RESTIC_PASSWORD_FILE=${repoConfig.passwordFile}"
              ];
              EnvironmentFile = lib.mkIf (repoConfig.environmentFile != null) repoConfig.environmentFile;
            } // lib.optionalAttrs (repoConfig.type == "local") {
              ReadWritePaths = [ repoConfig.url ];
            };

            script = ''
              set -euo pipefail
              echo "Checking Restic repository ${repoName} at ${repoConfig.url}..."

              # For remote repositories, check if already initialized
              if ${pkgs.restic}/bin/restic cat config >/dev/null 2>&1; then
                echo "Repository ${repoName} already initialized, skipping."
                exit 0
              fi

              echo "Initializing Restic repository ${repoName} at ${repoConfig.url}..."
              ${pkgs.restic}/bin/restic init
              echo "Repository ${repoName} initialized successfully."
            '';
          };
        })
        cfg.repositories))
    ];

    # Ensure backup user and group exist
    users.users.restic-backup = {
      isSystemUser = true;
      group = "restic-backup";
      description = "Restic backup service user";
      # Add to service groups to access their data directories
      extraGroups = [
        "grafana"
        "loki"
        "plex"
        "sonarr"
        "dispatcharr"
        "promtail"
        "observability"
        "postgres"
        "node-exporter"
      ];
    };

    users.groups.restic-backup = { };

    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d ${cfg.performance.cacheDir} 0750 restic-backup restic-backup -"
      "d /var/log/backup 0755 root root -"
      "d /var/lib/node_exporter/textfile_collector 0755 root root -"
      "d /tmp/restore-tests 0750 restic-backup restic-backup -"
      "d /var/lib/backup-snapshots 0755 root root -" # For ZFS clone mounts (avoids PrivateTmp conflicts)
    ];

    # Validation assertions
    assertions = [
      {
        assertion = (!cfg.restic.enable) || cfg.repositories != { };
        message = "At least one backup repository must be configured";
      }
      {
        assertion = lib.length (lib.filter (repo: repo.primary) (lib.attrValues cfg.repositories)) <= 1;
        message = "Only one repository can be marked as primary";
      }
    ];
  };
}
