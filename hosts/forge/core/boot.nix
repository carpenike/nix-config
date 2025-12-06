{ ... }:

{
  # Boot loader configuration
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # ZFS configuration for boot
  # Note: forceImportRoot and other ZFS settings are in _modules/nixos/filesystems/zfs

  # Ensure ZFS is supported in initrd
  boot.supportedFilesystems = [ "zfs" ];
}
