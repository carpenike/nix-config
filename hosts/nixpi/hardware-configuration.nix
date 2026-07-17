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

  # The SD image rootfs is populated with /nix/store. Since this appliance
  # mounts that partition at /nix, bind the nested store to runtime /nix/store
  # as a real mount; nix-daemon refuses symlinked store paths.
  fileSystems."/nix/store" = {
    device = "/nix/nix/store";
    fsType = "none";
    options = [ "bind" "ro" "nosuid" "nodev" "noatime" ];
    neededForBoot = true;
    depends = [ "/nix" ];
  };

  # The SD image stores extlinux, kernels, and initrds in the ext4 root
  # partition. That partition is mounted at /nix on this appliance, so expose
  # its boot directory at the conventional runtime path. Otherwise rebuilds
  # update the FAT firmware partition while U-Boot keeps reading the stale
  # /boot directory from NIXOS_SD.
  fileSystems."/boot" = {
    device = "/nix/boot";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/nix" ];
  };

  # Raspberry Pi firmware only; generic-extlinux boot artifacts live above.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # High performance mode
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
}
