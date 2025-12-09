{ lib
, mylib
, pkgs
, config
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

  # Only cfg is needed at top level for mkIf condition
  cfg = config.modules.services.profilarr;
in
{
  options.modules.services.profilarr = {
    enable = lib.mkEnableOption "Profilarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/profilarr";
      description = "Path to Profilarr data directory containing config.yml and profiles/";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "918";
      description = "User account under which Profilarr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Profilarr runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/profilarr/profilarr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Avoid 'latest' tag for production systems
      '';
      example = "ghcr.io/profilarr/profilarr:v1.0.0@sha256:f3ad4f59e6e5e4a...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = ''
        Systemd timer schedule for running Profilarr sync.
        Can be a systemd.time calendar specification like "daily", "weekly", "hourly", or "*-*-* 03:00:00".
      '';
      example = "*-*-* 03:00:00";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach the container to.
        Enables DNS resolution between containers on the same network.
      '';
      example = "media-services";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Profilarr";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Profilarr data.

        Profilarr stores config.yml and profile definitions that should be backed up.

        Recommended recordsize: 16K
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Profilarr profile sync failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Profilarr service events";
    };

    # Dataset configuration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Profilarr data directory";
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
          sequentially until one succeeds. Examples:
          - [ "syncoid" "local" "restic" ] - Default, try replication first
          - [ "local" "restic" ] - Skip replication, try local snapshots first
          - [ "restic" ] - Restic-only (for air-gapped systems)
          - [ "local" "restic" "syncoid" ] - Local-first for quick recovery
        '';
      };
    };
  };

  config =
    let
      # Move config-dependent variables here to avoid infinite recursion
      storageCfg = config.modules.storage;
      datasetPath = "${storageCfg.datasets.parentDataset}/profilarr";

      # Recursively find the replication config
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

      mainServiceUnit = "profilarr.service";
      hasCentralizedNotifications = config.modules.notifications.alertmanager.enable or false;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.backup != null -> cfg.backup.enable;
            message = "Profilarr backup must be explicitly enabled when configured";
          }
          {
            assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
            message = "Profilarr preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
            message = "Profilarr preseed.enable requires preseed.passwordFile to be set.";
          }
        ];

        warnings =
          (lib.optional (cfg.backup == null) "Profilarr has no backup configured. Profile configurations will not be protected.");

        # Create ZFS dataset for Profilarr data
        modules.storage.datasets.services.profilarr = {
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

        # Create system user for Profilarr
        users.users.profilarr = {
          uid = lib.mkDefault (lib.toInt cfg.user);
          group = cfg.group;
          isSystemUser = true;
          description = "Profilarr service user";
        };

        # Create system group for Profilarr
        users.groups.profilarr = {
          gid = lib.mkDefault (lib.toInt cfg.user);
        };

        # Profilarr sync service (oneshot)
        # This is NOT a long-running container - it's executed on a schedule
        systemd.services."profilarr-sync" = lib.mkMerge [
          (lib.mkIf (cfg.podmanNetwork != null) {
            requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
            after = [ "podman-network-${cfg.podmanNetwork}.service" ];
          })
          {
            description = "Profilarr Profile Sync";
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];

            serviceConfig = {
              Type = "oneshot";
              User = cfg.user;
              Group = cfg.group;

              # Run Profilarr container in one-shot mode
              ExecStart = ''
                ${pkgs.podman}/bin/podman run --rm \
                  --name profilarr-sync \
                  --user ${cfg.user}:${toString config.users.groups.${cfg.group}.gid} \
                  --log-driver=journald \
                  ${lib.optionalString (cfg.podmanNetwork != null) "--network=${cfg.podmanNetwork}"} \
                  -v ${cfg.dataDir}:/config:rw \
                  -e TZ=${cfg.timezone} \
                  ${cfg.image}
              '';

              # Cleanup on failure
              ExecStopPost = ''
                -${pkgs.podman}/bin/podman rm -f profilarr-sync
              '';
            };
          }
        ];

        # Systemd timer to trigger the sync service
        systemd.timers."profilarr-sync" = {
          description = "Profilarr Profile Sync Timer";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.schedule;
            Persistent = true;
            RandomizedDelaySec = "5m";
          };
        };

        # Backup integration using standardized restic pattern
        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          profilarr = {
            enable = true;
            paths = [ cfg.dataDir ];
            repository = cfg.backup.repository;
            frequency = cfg.backup.frequency;
            tags = cfg.backup.tags;
            excludePatterns = cfg.backup.excludePatterns;
            useSnapshots = cfg.backup.useSnapshots;
            zfsDataset = cfg.backup.zfsDataset;
          };
        };
      })

      # Preseed service
      (lib.mkIf (cfg.enable && cfg.preseed.enable) (
        storageHelpers.mkPreseedService {
          serviceName = "profilarr";
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
