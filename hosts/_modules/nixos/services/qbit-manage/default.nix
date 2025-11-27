{ lib
, pkgs
, config
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared types
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.qbit-manage;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  datasetPath = "${storageCfg.datasets.parentDataset}/qbit-manage";
  mainServiceUnit = "qbit-manage.service";
  qbittorrentServiceUnit = "${config.virtualisation.oci-containers.backend}-qbittorrent.service";

  # Recursively find replication config from parent datasets
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };

  # Generate YAML configuration for qbit_manage
  yamlFormat = pkgs.formats.yaml { };

  # This is the core config - users should customize via extraConfig for tracker rules
  baseConfig = {
    # qBittorrent connection
    qbt = {
      host = cfg.qbittorrent.host;
      port = cfg.qbittorrent.port;
    } // lib.optionalAttrs (cfg.qbittorrent.login != null) {
      user = cfg.qbittorrent.login;
    } // lib.optionalAttrs (cfg.qbittorrent.password != null) {
      pass = cfg.qbittorrent.password;
    };

    # Directory configuration
    directory = {
      # Root directory for content
      root_dir = cfg.contentDirectory;
      # Remote path mapping (for Docker/container setups)
      remote_dir = cfg.remoteDirectory;
      # Recycle bin for safety
      recycle_bin = cfg.recycleBinEnabled;
      recycle_bin_path = "${cfg.dataDir}/RecycleBin";
      # Orphaned file cleanup
      orphaned_dir = "${cfg.dataDir}/orphaned_data";
    };

    # Core behaviors
    settings = {
      # Force category checking
      force_auto_tmm = false;
      # Tracker error handling
      tracker_error_tag = "issue";
      # Ignore private trackers for some operations
      ignoreTorrents_SmallerThan = 0;
      # Dry run mode (for testing)
      dry_run = cfg.dryRun;
    };
  };

  configFile = yamlFormat.generate "config.yml" (
    lib.recursiveUpdate baseConfig cfg.extraConfig
  );
in
{
  options.modules.services.qbit-manage = {
    enable = lib.mkEnableOption "qbit_manage - comprehensive qBittorrent lifecycle management";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.qbit-manage or (pkgs.python3Packages.callPackage ./package.nix { });
      description = "The qbit_manage package to use";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qbit-manage";
      description = "Path to qbit_manage data directory (logs, state, recycle bin)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "qbit-manage";
      description = "User account under which qbit_manage runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "qbit-manage";
      description = "Group under which qbit_manage runs";
    };

    # qBittorrent connection settings
    qbittorrent = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "qBittorrent host";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "qBittorrent WebUI port";
      };

      login = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "qBittorrent WebUI login (null if auth disabled on local network)";
      };

      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "qBittorrent WebUI password (null if auth disabled on local network)";
      };
    };

    # Directory settings
    contentDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/downloads";
      description = "Root directory where torrent content is stored";
    };

    remoteDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Remote path mapping if qBittorrent is in a container";
      example = "/downloads";
    };

    recycleBinEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Move deleted data to recycle bin instead of permanent deletion";
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable dry-run mode (no actual changes made)";
    };

    # Scheduling
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*/15 * * * *"; # Every 15 minutes
      description = "Systemd timer schedule (OnCalendar format)";
      example = "*/30 * * * *"; # Every 30 minutes
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Additional qbit_manage configuration (merged with base config).

        CRITICAL: You MUST define tracker-specific seeding rules here.
        See TRaSH Guides: https://trash-guides.info/qbit_manage/settings/

        Example:
        {
          tracker = {
            "tracker.example.com" = {
              tag = "example";
              max_ratio = 2.0;
              max_seeding_time = 20160;  # 14 days in minutes
              limit_upload_speed = 1000;  # KB/s
            };
          };
          cat = {
            "radarr" = {
              # Category-specific rules
              save_path = "/downloads/qb/downloads/radarr";
            };
          };
        }
      '';
      example = lib.literalExpression ''
        {
          # Tracker-specific seeding rules (REQUIRED for private trackers)
          tracker = {
            "tracker.example.com" = {
              tag = "example";
              max_ratio = 2.0;
              max_seeding_time = 20160;  # 14 days
            };
          };

          # Category rules
          cat = {
            "radarr" = {
              save_path = "/downloads/qb/downloads/radarr";
            };
          };

          # Orphan file cleanup
          orphaned = {
            exclude_patterns = [ "*.partial" "*.!qB" ];
          };
        }
      '';
    };

    # Standardized submodules
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        paths = [ cfg.dataDir ];
        repository = "nas-primary";
        frequency = "daily";
        retention = {
          daily = 7;
          weekly = 4;
          monthly = 3;
        };
        useSnapshots = false;
        excludePatterns = [
          "*.log"
          "RecycleBin/*"
          "orphaned_data/*"
        ];
      };
      description = "Backup configuration for qbit_manage data";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default =
        if hasCentralizedNotifications then {
          enable = true;
          channels = {
            onFailure = [ "critical-alerts" ];
          };
          customMessages = {
            failure = "qbit_manage failed on ${config.networking.hostName}";
          };
        } else null;
      description = "Notification configuration";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Assertions for critical configuration
      assertions = [
        {
          assertion = lib.length (lib.attrNames (cfg.extraConfig.tracker or { })) > 0;
          message = ''
            qbit_manage requires at least one tracker-specific seeding rule in extraConfig.tracker.
            See TRaSH Guides: https://trash-guides.info/qbit_manage/settings/

            Example:
            modules.services.qbit-manage.extraConfig = {
              tracker = {
                "tracker.example.com" = {
                  tag = "example";
                  max_ratio = 2.0;
                  max_seeding_time = 20160;
                };
              };
            };
          '';
        }
      ];

      # Create ZFS dataset for qbit-manage data
      modules.storage.datasets.services.qbit-manage = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for configuration files
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # User and group creation
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        description = "qbit_manage service user";
      };

      users.groups.${cfg.group} = { };

      # Systemd service (oneshot, triggered by timer)
      systemd.services.qbit-manage = {
        description = "qbit_manage - qBittorrent lifecycle management";
        after = [ "network-online.target" ]
          ++ lib.optional (config.modules.services.qbittorrent.enable or false) qbittorrentServiceUnit;
        wants = [ "network-online.target" ];

        # Restart tqm on failure (ensures tqm never left stopped)
        # Combined with notification failure handling below
        onFailure = lib.optionals (config.modules.services.tqm.enable or false) [ "tqm.service" ]
          ++ lib.optional (cfg.notifications != null && cfg.notifications.enable) "notify-failure@%n.service";

        # Wait for qBittorrent to be available and validate content directory
        preStart = ''
            # Validate content directory exists and is writable (actual I/O test)
            if ! touch "${cfg.contentDirectory}/.qbit-manage-healthcheck" 2>/dev/null; then
              echo "ERROR: contentDirectory '${cfg.contentDirectory}' is not writable or not responsive (stale NFS mount?)" >&2
              exit 1
            fi        ${lib.optionalString (config.modules.services.qbittorrent.enable or false) ''
            # Wait for qBittorrent to become available
            for i in {1..30}; do
              if ${pkgs.curl}/bin/curl -sf http://${cfg.qbittorrent.host}:${toString cfg.qbittorrent.port}/api/v2/app/version > /dev/null 2>&1; then
                echo "qBittorrent is ready"
                break
              fi
              echo "Waiting for qBittorrent... ($i/30)"
              sleep 2
              if [ "$i" -eq 30 ]; then
                echo "ERROR: qBittorrent did not become available after 60 seconds" >&2
                exit 1
              fi
            done
          ''}
        '';

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;

          # Mutual exclusion: stop tqm before running, restart after success
          # Prevents race conditions where both tools modify same torrents
          # If qbit-manage fails, onFailure restarts tqm instead
          ExecStartPre = lib.mkIf (config.modules.services.tqm.enable or false) "+${pkgs.systemd}/bin/systemctl stop tqm.service";
          ExecStart = "${cfg.package}/bin/qbit_manage --config ${configFile} --log-file ${cfg.dataDir}/qbit_manage.log";
          ExecStartPost = lib.mkIf (config.modules.services.tqm.enable or false) "+${pkgs.systemd}/bin/systemctl start tqm.service";

          # Security hardening
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;

          # Resource limits
          MemoryMax = "512M";
          CPUQuota = "50%";

          # Directory permissions
          ReadWritePaths = [
            cfg.dataDir
            cfg.contentDirectory
          ];
          StateDirectory = "qbit-manage";
        };
      };

      # Systemd timer for periodic execution
      systemd.timers.qbit-manage = {
        description = "qbit_manage periodic execution timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m"; # Wait 5 minutes after boot
          OnCalendar = cfg.schedule;
          Persistent = true; # Run immediately if missed
          Unit = "qbit-manage.service";
        };
      };

      # Firewall (localhost only, no ports needed)
      networking.firewall.interfaces.lo.allowedTCPPorts = [ ];

      # Backup integration
      # Auto-register backup job if backup is enabled
      modules.backup.restic.jobs.qbit-manage = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        paths = cfg.backup.paths;
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency;
        retention = cfg.backup.retention;
        useSnapshots = cfg.backup.useSnapshots;
        excludePatterns = cfg.backup.excludePatterns;
        preBackupScript = cfg.backup.preBackupScript;
        postBackupScript = cfg.backup.postBackupScript;
      };
    })

    # Preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "qbit-manage";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
