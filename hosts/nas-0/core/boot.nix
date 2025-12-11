# hosts/nas-0/core/boot.nix
#
# Boot and kernel configuration for nas-0
#
# Uses the default NixOS kernel for ZFS compatibility.
# DO NOT use linuxPackages_latest - it may break ZFS.

{ pkgs, ... }:

{
  # =============================================================================
  # Boot Loader
  # =============================================================================

  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
      editor = false; # Security: disable boot entry editing
    };
    efi.canTouchEfiVariables = true;
    timeout = 3;
  };

  # =============================================================================
  # Kernel Configuration
  # =============================================================================

  # Use the default NixOS kernel (6.12.x as of 24.11)
  # This is tested and compatible with ZFS
  # DO NOT use linuxPackages_latest without verifying ZFS compatibility
  boot.kernelPackages = pkgs.linuxPackages;

  # Kernel parameters
  boot.kernelParams = [
    # ZFS tuning for large storage server
    "zfs.zfs_arc_max=34359738368" # 32GB ARC max (half of 64GB RAM)
  ];

  # =============================================================================
  # ZFS Support
  # =============================================================================

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

  # Request encryption credentials (if any encrypted datasets)
  boot.zfs.requestEncryptionCredentials = true;

  # =============================================================================
  # initrd Configuration
  # =============================================================================

  boot.initrd = {
    availableKernelModules = [
      "xhci_pci"
      "ahci"
      "ehci_pci"
      "usbhid"
      "usb_storage"
      "sd_mod"
      "sr_mod"
      # Intel 10GbE driver for ix0
      "ixgbe"
    ];
    kernelModules = [ ];
  };

  # Additional kernel modules
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # =============================================================================
  # Hardware Configuration
  # =============================================================================

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Power management for always-on NAS
  powerManagement.cpuFreqGovernor = "ondemand";
}
