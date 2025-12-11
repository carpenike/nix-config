# hosts/nas-0/default.nix
#
# nas-0: Primary bulk storage NAS
#
# Hardware:
#   - CPU: Intel i3-7100 (2C/4T @ 3.9GHz)
#   - RAM: 64GB DDR4
#   - Boot: 64GB Transcend MTS600 SSD
#   - Storage: tank pool - 117TB across 14 mirror vdevs (28 drives)
#
# Role:
#   - Primary storage for media services (Plex, *arr stack on forge)
#   - NFS exports: /mnt/tank/share, /mnt/tank/home
#   - SMB shares for Windows/macOS access
#   - ZFS replication source to nas-1

{ ... }:

let
  # Boot disk - 64GB Transcend MTS600 SSD
  # Serial: G016180039
  bootDisk = "/dev/disk/by-id/ata-TS64GMTS600_G016180039";
in
{
  imports = [
    # Disko configuration for boot disk only
    # tank pool is imported separately (not recreated)
    (import ./disko-config.nix { disks = [ bootDisk ]; })

    # Core system configuration
    ./core/boot.nix
    ./core/networking.nix
    ./core/users.nix
    ./core/packages.nix
    ./core/hardware.nix
    ./core/monitoring.nix # node_exporter for Prometheus scraping by forge

    # Infrastructure
    ./infrastructure/storage.nix
    ./infrastructure/nfs.nix
    ./infrastructure/smb.nix

    # Secrets
    ./secrets.nix
  ];

  # =============================================================================
  # Host Identification
  # =============================================================================

  networking.hostName = "nas-0";

  # CRITICAL: hostId is required for ZFS pool imports
  # Derived from TrueNAS hostuuid: 00000000-0000-0000-0000-ac1f6b1a8e40
  # Using last 8 hex chars of the MAC-based UUID
  networking.hostId = "6b1a8e40";

  # =============================================================================
  # System Configuration
  # =============================================================================

  system.stateVersion = "24.11";
  time.timeZone = "America/New_York";

  # =============================================================================
  # Impermanence Configuration
  # =============================================================================

  # Enable impermanence with root rollback to @blank snapshot
  modules.system.impermanence.enable = true;

  # Persist critical system state
  modules.system.impermanence.directories = [
    "/var/lib/tailscale"
  ];

  modules.system.impermanence.files = [
    "/var/lib/sops-nix/key.txt"
  ];

  # =============================================================================
  # Core Services
  # =============================================================================

  # Tailscale for secure remote access
  services.tailscale.enable = true;

  # Enable SMART monitoring for the many drives
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      wall.enable = true;
      # TODO: Configure email/push notifications
    };
  };

  # SSH access (repo-wide configuration via modules)
  services.openssh.enable = true;

  # =============================================================================
  # ZFS Configuration
  # =============================================================================

  # Import the existing tank pool (not managed by disko)
  # This is the primary 117TB storage pool with 14 mirror vdevs
  boot.zfs.extraPools = [ "tank" ];

  # Enable ZFS services
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
      pools = [ "tank" ];
    };
    trim = {
      enable = true;
      interval = "weekly";
    };
  };
}
