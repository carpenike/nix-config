{ config, pkgs, ... }:
{
  # Temporary filesystems to reduce SD card wear
  fileSystems."/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "mode=1777" ];
  };

  fileSystems."/var/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "mode=1777" ];
  };

  # Configuration for the mSATA SSD (if present)
  # These mounts will fail gracefully if the SSD is not present due to 'nofail'
  fileSystems."/var/log" = {
    device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
    fsType = "btrfs";
    options = [ "defaults" "nofail" "subvol=@var_log" "compress=zstd" ];
  };

  fileSystems."/var/cache" = {
    device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
    fsType = "btrfs";
    options = [ "defaults" "nofail" "subvol=@var_cache" "compress=zstd" ];
  };

  # Persistent configuration for rvc2api on the SSD
  fileSystems."/srv/rvc2api/config" = {
    device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
    fsType = "btrfs";
    options = [ "defaults" "nofail" "subvol=@rvc2api_config" "compress=zstd" ];
  };
}
