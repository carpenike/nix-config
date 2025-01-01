{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.modules.filesystems.zfs;
in
{
  options.modules.filesystems.zfs = {
    enable = lib.mkEnableOption "zfs";
    mountPoolsAtBoot = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of ZFS pools to mount at boot";
    };
  };

  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      zfs = {
        package = pkgs.zfs_unstable;
        forceImportRoot = true;
        requestEncryptionCredentials = true;
        extraPools = cfg.mountPoolsAtBoot;
      };
    };

    # Use standard fileSystems configuration for ZFS mounts
    fileSystems."/persist" = {
      device = "rpool/safe/persist";
      fsType = "zfs";
      neededForBoot = true;
    };

    fileSystems."/home" = {
      device = "rpool/safe/home";
      fsType = "zfs";
      neededForBoot = true;
    };

    # Optional: ZFS services
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };
  };
}
