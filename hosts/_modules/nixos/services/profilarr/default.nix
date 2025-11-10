{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

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

    # Dataset configuration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Profilarr data directory";
    };
  };

  config = lib.mkIf cfg.enable (
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
            replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
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
    in
    {
    assertions = [
      {
        assertion = cfg.backup != null -> cfg.backup.enable;
        message = "Profilarr backup must be explicitly enabled when configured";
      }
    ];

    warnings =
      (lib.optional (cfg.backup == null) "Profilarr has no backup configured. Profile configurations will not be protected.");

    # Create ZFS dataset for Profilarr data
    modules.storage.datasets.services.profilarr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for configuration files
      compression = "zstd";
      properties = {
        "com.sun:auto-snapshot" = "true";
      };
      owner = "profilarr";
      group = "profilarr";
      mode = "0750";
    };

    # Create system user for Profilarr
    users.users.profilarr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = cfg.group;
      isSystemUser = true;
      description = "Profilarr service user";
    };

    # Profilarr sync service (oneshot)
    # This is NOT a long-running container - it's executed on a schedule
    systemd.services."profilarr-sync" = {
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
            --log-driver=${if cfg.logging != null && cfg.logging.enable then cfg.logging.driver else "journald"} \
            -v ${cfg.dataDir}:/config:rw \
            -e TZ=${cfg.timezone} \
            ${cfg.image}
        '';

        # Cleanup on failure
        ExecStopPost = ''
          -${pkgs.podman}/bin/podman rm -f profilarr-sync
        '';
      };
    };

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

    # Preseed service for disaster recovery
    systemd.services."profilarr-preseed" = lib.mkIf (cfg.backup != null && cfg.backup.preseed.enable && replicationConfig != null) (
      storageHelpers.makePreseedService {
        serviceName = "profilarr";
        datasetPath = datasetPath;
        mountPoint = cfg.dataDir;
        targetServiceUnit = "profilarr-sync.service";
        replicationConfig = replicationConfig;
        restoreMethods = cfg.backup.preseed.restoreMethods;
        resticRepository = if cfg.backup.preseed.enableResticRestore then cfg.backup.repository else null;
        user = cfg.user;
        group = cfg.group;
      }
    );
  }
  );
}
