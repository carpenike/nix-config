# hosts/nas-1/core/hardware.nix
#
# Hardware configuration for nas-1
#
# Hardware:
# - CPU: Intel Core i3-7100 @ 3.90GHz (2C/4T)
# - RAM: 32GB
# - Boot: 60GB SSD (Kingston SA400)
# - Data: 4x 12.7TB HDD (RAIDZ1)

{ lib, ... }:

{
  # =============================================================================
  # Hardware Detection
  # =============================================================================

  hardware.enableRedistributableFirmware = true;

  # CPU microcode
  hardware.cpu.intel.updateMicrocode = true;

  # =============================================================================
  # Filesystems
  # =============================================================================

  # The main filesystems are managed by disko and ZFS
  # This just adds any additional mount options

  fileSystems."/boot" = {
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # =============================================================================
  # Power Management
  # =============================================================================

  # For a NAS, we want to prioritize availability over power savings
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Enable SMART monitoring for drives
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      wall.enable = true;
      # TODO: Add email/notification on SMART failures
    };
  };

  # =============================================================================
  # nixpkgs Configuration
  # =============================================================================

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
