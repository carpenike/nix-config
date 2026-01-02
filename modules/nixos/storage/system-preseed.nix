{ lib, pkgs, ... }:
let
  # IMPORTANT: Direct import required here - cannot use mylib.storageHelpers
  # because accessing _module.args.mylib would require config evaluation,
  # causing infinite recursion. This module runs at top-level before config.
  # See: https://github.com/NixOS/nixpkgs/blob/master/lib/modules.nix#L297
  storageHelpers = import ./helpers-lib.nix { inherit pkgs lib; };
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
  # Avoid any `config` references to prevent recursion; use safe defaults.
  config = lib.mkMerge [
    (
      (storageHelpers.mkPreseedService {
        serviceName = "system-persist";
        dataset = "rpool/persist";
        mountpoint = "/persist";
        mainServiceUnit = "multi-user.target";
        replicationCfg = null;
        datasetProperties = { recordsize = "128K"; compression = "lz4"; };
        resticRepoUrl = null;
        resticPasswordFile = null;
        resticEnvironmentFile = null;
        resticPaths = [ "/persist" ];
        restoreMethods = [ "syncoid" "local" ];
        hasCentralizedNotifications = false;
        owner = "root";
        group = "root";
      }) // (mkUnitExt "system-persist" "/persist")
    )

    (
      (storageHelpers.mkPreseedService {
        serviceName = "system-home";
        dataset = "rpool/safe/home";
        mountpoint = "/home";
        mainServiceUnit = "multi-user.target";
        replicationCfg = null;
        datasetProperties = { recordsize = "128K"; compression = "lz4"; };
        resticRepoUrl = null;
        resticPasswordFile = null;
        resticEnvironmentFile = null;
        resticPaths = [ "/home" ];
        restoreMethods = [ "syncoid" "local" ];
        hasCentralizedNotifications = false;
        owner = "root";
        group = "root";
      }) // (mkUnitExt "system-home" "/home")
    )
  ];
}
