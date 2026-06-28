{ lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # ESP32-style appliance: root is tmpfs (wiped each boot). Only /nix and the
  # impermanence /persist store hold real data, so the SD is read-mostly firmware.
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  # Immutable Nix store on the SD card; written only during deploys.
  fileSystems."/nix" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
    neededForBoot = true;
  };

  # Firmware + kernel (vfat); 512 MiB on the rebuilt image so the kernel fits.
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

  # Persistent state on the USB SSD (impermanence target). nofail so the box
  # still boots (ephemeral) if the SSD is absent.
  fileSystems."/persist" = {
    device = "/dev/disk/by-id/usb-SABRENT_ASM1153E_0000000000B7-0:0-part1";
    fsType = "btrfs";
    options = [ "subvol=@persist" "compress=zstd" "noatime" "nofail" ];
    neededForBoot = true;
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # High performance mode
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
}
