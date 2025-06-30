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

    # ZFS services configuration
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    # Disable ZED service entirely since we don't need event notifications
    # ZED exits when it has no configured actions (no email, no other zlets)
    systemd.services.zfs-zed.enable = false;
  };
}
