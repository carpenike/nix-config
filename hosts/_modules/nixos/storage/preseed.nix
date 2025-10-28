{ lib, pkgs, config, ... }:
let
  cfg = config.modules.storage.preseed;
  storageHelpers = import ./helpers-lib.nix { inherit pkgs lib; };

  # Helper: find replication config from Sanoid datasets if present
  getReplicationCfg = dataset: let
    ds = (config.modules.backup.sanoid.datasets or {}).
      ${dataset} or null;
    repl = if ds == null then null else (ds.replication or null);
  in if repl == null then null else {
    targetHost = repl.targetHost;
    targetDataset = repl.targetDataset;
    sshUser = (repl.targetUser or config.modules.backup.sanoid.replicationUser or "zfs-replication");
    sshKeyPath = (config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519");
    sendOptions = (repl.sendOptions or "w");
    recvOptions = (repl.recvOptions or "u");
  };

  # Resolve system-level datasets for /persist and /home
  persistDataset = (config.fileSystems."/persist".device or null);
  homeDataset = (config.fileSystems."/home".device or null);

  # Choose a Restic repository URL if available (optional)
  resticRepos = (config.modules.backup.restic.repositories or {});
  resticRepoUrl = cfg.repositoryUrl or (
    if resticRepos == {} then null
    else (let first = lib.head (lib.attrValues resticRepos); in (first.url or null))
  );
  resticPasswordFile = cfg.passwordFile or null;
in {
  options.modules.storage.preseed = {
    enable = lib.mkEnableOption "global pre-seed of ZFS-backed storage (default-on)" // { default = true; };

    restoreMethods = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
      default = [ "syncoid" "local" "restic" ];
      description = "Order of restore methods attempted during pre-seed.";
    };

    repositoryUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Restic repository URL for system-level preseed (optional). If null, tries first configured repository if any.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to Restic password file for system-level preseed (optional).";
    };

    paths = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkOption { type = lib.types.bool; default = true; };
          dataset = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          mountpoint = lib.mkOption { type = lib.types.str; description = "Absolute mountpoint path."; };
          owner = lib.mkOption { type = lib.types.str; default = "root"; };
          group = lib.mkOption { type = lib.types.str; default = "root"; };
          restoreMethods = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
            default = cfg.restoreMethods;
          };
        };
      });
      default = lib.mkMerge [
        (lib.optionalAttrs (persistDataset != null) {
          "/persist" = {
            enable = true;
            dataset = persistDataset;
            mountpoint = "/persist";
            owner = "root";
            group = "root";
          };
        })
        (lib.optionalAttrs (homeDataset != null) {
          "/home" = {
            enable = true;
            dataset = homeDataset;
            mountpoint = "/home";
            owner = "root";
            group = "root";
          };
        })
      ];
      description = "System-level preseed paths (default include /persist and /home when backed by ZFS).";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Build service definitions for each enabled path
      pathServices = lib.mapAttrsToList (p: pcfg:
        lib.mkIf pcfg.enable (
          storageHelpers.mkPreseedService {
            serviceName = "system" + (lib.strings.replaceStrings ["/"] ["-"] p);
            dataset = pcfg.dataset or "";
            mountpoint = pcfg.mountpoint;
            mainServiceUnit = "multi-user.target";
            replicationCfg = if pcfg.dataset != null then getReplicationCfg pcfg.dataset else null;
            datasetProperties = { recordsize = "128K"; compression = "lz4"; };
            resticRepoUrl = resticRepoUrl;
            resticPasswordFile = resticPasswordFile;
            resticEnvironmentFile = null;
            resticPaths = [ p ];
            restoreMethods = pcfg.restoreMethods;
            hasCentralizedNotifications = (config.modules.notifications.enable or false);
            owner = pcfg.owner; group = pcfg.group;
          }
        )
      ) cfg.paths;

      # Extend units to join storage-preseed.target and require mounts
      unitExtensions = lib.mapAttrsToList (p: pcfg:
        let unitName = "preseed-" + "system" + (lib.strings.replaceStrings ["/"] ["-"] p);
        in {
          systemd.services."${unitName}".unitConfig = lib.mkMerge [
            { PartOf = [ "storage-preseed.target" ]; }
            { RequiresMountsFor = [ pcfg.mountpoint ]; }
          ];
        }
      ) cfg.paths;

      preseedTarget = {
        systemd.targets.storage-preseed = {
          description = "Storage Preseed (restore persistent data before services)";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs-import.target" "zfs-mount.service" "systemd-tmpfiles-setup.service" ];
        };
      };
    in lib.mkMerge ([ preseedTarget ] ++ pathServices ++ unitExtensions)
  );
}
