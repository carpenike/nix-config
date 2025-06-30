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
      # Disable ZED if it's not needed or configure it properly
      zed = {
        enableMail = false;
        settings = {
          ZED_DEBUG_LOG = "/tmp/zed.debug.log";
          ZED_EMAIL_ADDR = [ "root" ];
          ZED_EMAIL_PROG = "mail";
          ZED_EMAIL_OPTS = "-s '@SUBJECT@' @ADDRESS@";
          ZED_NOTIFY_INTERVAL_SECS = 3600;
          ZED_NOTIFY_VERBOSE = false;
          ZED_USE_ENCLOSURE_LEDS = true;
          ZED_SCRUB_AFTER_RESILVER = false;
        };
      };
    };
  };
}
