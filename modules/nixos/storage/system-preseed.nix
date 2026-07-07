{ config, lib, pkgs, ... }:
let
  # IMPORTANT: Direct import required here - cannot use mylib.storageHelpers
  # because accessing _module.args.mylib would require config evaluation,
  # causing infinite recursion. This module runs at top-level before config.
  # See: https://github.com/NixOS/nixpkgs/blob/master/lib/modules.nix#L297
  storageHelpers = import ./helpers-lib.nix { inherit pkgs lib; };

  # Resolve replication config from the host's sanoid dataset tree (e.g. on
  # forge: rpool/safe/persist -> nas-1:backup/forge/zfs-recv/persist). Reading
  # plain option values (modules.backup.sanoid.*) is safe; only _module.args
  # access causes the recursion described above. Null when the host doesn't
  # replicate these datasets - preseed then has no remote restore source.
  mkSystemReplication = datasetPath:
    storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Shared safety settings for host system datasets:
  # - legacy mounts (disko fileSystems manage them - never rewrite mountpoint)
  # - mixed file ownership (never recursively chown after restore)
  # - never mark an empty dataset preseed_complete (host key material lives
  #   in /persist; an empty restore must keep signalling until fixed)
  # - existing snapshots mean the dataset is live: mark complete and skip
  mkSystemPreseed = { serviceName, dataset, mountpoint }:
    storageHelpers.mkPreseedService {
      inherit serviceName dataset mountpoint;
      mainServiceUnit = "multi-user.target";
      replicationCfg = mkSystemReplication dataset;
      datasetProperties = { recordsize = "128K"; compression = "lz4"; };
      resticRepoUrl = null;
      resticPasswordFile = null;
      resticEnvironmentFile = null;
      resticPaths = [ mountpoint ];
      restoreMethods = [ "syncoid" "local" ];
      hasCentralizedNotifications = false;
      owner = "root";
      group = "root";
      chownRestored = false;
      manageMountpoint = false;
      markCompleteOnFailure = false;
      skipIfSnapshotsExist = true;
    };

  mkUnitExt = name: mountpoint: {
    systemd.services."preseed-${name}".unitConfig = {
      # Ensure mount exists before running
      RequiresMountsFor = [ mountpoint ];
      # Bind lifecycle to the aggregation target
      PartOf = [ "storage-preseed.target" ];
    };
  };
in
{
  config = lib.mkIf config.modules.storage.preseed.enable (lib.mkMerge [
    # NOTE: these are separate mkMerge entries (NOT combined with `//`) - a
    # shallow `//` merge would clobber the whole `systemd` attrset from
    # mkPreseedService with the unitConfig-only attrset from mkUnitExt,
    # leaving a service with no ExecStart.
    # Dataset names must match disko-config (rpool/safe/persist -> /persist,
    # rpool/safe/home -> /home).
    (mkSystemPreseed {
      serviceName = "system-persist";
      dataset = "rpool/safe/persist";
      mountpoint = "/persist";
    })
    (mkUnitExt "system-persist" "/persist")

    (mkSystemPreseed {
      serviceName = "system-home";
      dataset = "rpool/safe/home";
      mountpoint = "/home";
    })
    (mkUnitExt "system-home" "/home")
  ]);
}
