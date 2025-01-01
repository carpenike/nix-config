{
  lib,
  config,
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
    };
  };

  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      zfs = {
        forceImportRoot = true; # Temporarily enable for debugging
        extraPools = cfg.mountPoolsAtBoot;
      };
    };

    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    # Ensure ZFS pool is mounted at boot
    modules.filesystems.zfs = {
      enable = true;
      mountPoolsAtBoot = [ "rpool" ]; # Add your pool name here
    };

    # Explicit fileSystems entries (if not defined elsewhere)
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
  };
}
