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
    persistDataset = lib.mkOption {
      type = lib.types.str;
      default = "rpool/safe/persist";
      description = "ZFS dataset to mount at /persist";
    };
    homeDataset = lib.mkOption {
      type = lib.types.str;
      default = "rpool/safe/home";
      description = "ZFS dataset to mount at /home";
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
    # These are typically defined by disko-config.nix, but we provide defaults
    # Note: disko-config definitions take precedence over these
    fileSystems."/persist" = lib.mkDefault {
      device = cfg.persistDataset;
      fsType = "zfs";
      neededForBoot = true;
    };

    fileSystems."/home" = lib.mkDefault {
      device = cfg.homeDataset;
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
