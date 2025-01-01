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
      description = "List of ZFS pools to mount at boot";
    };
  };

  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      zfs = {
        forceImportRoot = true; # Enable for debugging
        extraPools = cfg.mountPoolsAtBoot; # Ensure the pool is imported
      };
    };

    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    # Explicitly define dependencies for mount points
    systemd.mounts."/persist" = {
      what = "rpool/safe/persist";
      type = "zfs";
      options = [ "defaults" ];
      wantedBy = [ "local-fs.target" ];
      before = [ "local-fs.target" ];
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
    };

    systemd.mounts."/home" = {
      what = "rpool/safe/home";
      type = "zfs";
      options = [ "defaults" ];
      wantedBy = [ "local-fs.target" ];
      before = [ "local-fs.target" ];
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
    };
  };
}
