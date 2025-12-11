# hosts/nas-1/core/boot.nix
#
# Boot configuration for nas-1
# Uses systemd-boot with ZFS support

{ ... }:

{
  # =============================================================================
  # Boot Loader
  # =============================================================================

  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
      editor = false; # Security: disable boot entry editor
    };
    efi.canTouchEfiVariables = true;
    timeout = 3;
  };

  # =============================================================================
  # Kernel Configuration
  # =============================================================================

  # Use the default kernel - it's tested with ZFS
  # (linuxPackages_latest can have ZFS compatibility issues)
  # boot.kernelPackages = pkgs.linuxPackages;  # Use default

  # ZFS-specific kernel parameters
  boot.kernelParams = [
    "nohibernate" # ZFS doesn't support hibernation
  ];

  # =============================================================================
  # ZFS Support
  # =============================================================================

  boot.supportedFilesystems = [ "zfs" ];

  # ZFS auto-scrub (weekly)
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
    pools = [ "rpool" "backup" ];
  };

  # ZFS auto-trim (for SSDs in rpool)
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # =============================================================================
  # Initial RAM Filesystem
  # =============================================================================

  boot.initrd = {
    availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = [ ];
  };

  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
}
