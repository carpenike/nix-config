# hosts/nas-0/core/hardware.nix
#
# Hardware configuration for nas-0
#
# Hardware:
#   - CPU: Intel i3-7100 (2C/4T @ 3.9GHz)
#   - RAM: 64GB DDR4
#   - Boot: 64GB Transcend MTS600 SSD
#   - Storage: tank pool - 117TB across 14 mirror vdevs (28 drives)

{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # =============================================================================
  # CPU Configuration
  # =============================================================================

  # Intel i3-7100 (Kaby Lake)
  hardware.cpu.intel.updateMicrocode = true;

  # Power management - optimize for server workload
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # =============================================================================
  # Kernel Modules
  # =============================================================================

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  boot.kernelModules = [
    "kvm-intel"
    "coretemp" # CPU temperature monitoring
  ];

  # =============================================================================
  # Memory Configuration
  # =============================================================================

  # 64GB RAM - plenty for ZFS ARC
  # ZFS will use up to 50% by default, which is appropriate for a NAS

  # =============================================================================
  # Storage Controller Configuration
  # =============================================================================

  # The 28 drives are connected via HBA cards
  # No special configuration needed - standard AHCI/SAS drivers

  # =============================================================================
  # Firmware
  # =============================================================================

  hardware.enableRedistributableFirmware = true;
}
