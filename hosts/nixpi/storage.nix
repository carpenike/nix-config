{ lib, ... }:
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
  # The USB SSD layout is owned by disko-config.nix. Mark /persist as an
  # initrd mount because impermanence needs it before stage 2. The other SSD
  # subvolumes also mount in initrd so scripted stage 1 creates mountpoints on
  # the otherwise-empty tmpfs root before systemd starts.
  fileSystems."/persist".neededForBoot = lib.mkDefault true;
  fileSystems."/var/cache".neededForBoot = lib.mkDefault true;
  fileSystems."/var/lib/coachiq".neededForBoot = lib.mkDefault true;
}
