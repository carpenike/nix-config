# hosts/nas-1/default.nix
#
# NAS-1 Host Configuration
#
# Purpose: Secondary NAS / Backup Target
# - Receives ZFS replication from forge (via syncoid)
# - Receives ZFS replication from nas-0 (TrueNAS primary NAS)
# - Exports NFS shares for Restic and PostgreSQL backups
# - Minimal services: NFS, ZFS, Tailscale, SSH
#
# Architecture: Follows three-tier pattern (core → infrastructure → services)
# but with minimal services layer since this is a backup appliance.
#
# POST-MIGRATION CLEANUP:
# The following legacy ZFS datasets can be destroyed after migration is stable:
# - backup/forge/services (stale since 2025-10-14, replaced by zfs-recv/*)
# - backup/.system/* (TrueNAS Scale leftovers)
# - backup/cp0 (743GB - appears to be legacy TrueNAS data)
# Command: zfs destroy -r backup/forge/services backup/.system backup/cp0

{ ... }:

{
  imports = [
    # Hardware & Disk Configuration
    (import ./disko-config.nix {
      # Boot SSD - 64GB Transcend MTS600
      disks = [ "/dev/disk/by-id/ata-TS64GMTS600_G016180046" ];
    })

    # Core System Configuration
    ./core/boot.nix
    ./core/networking.nix
    ./core/users.nix
    ./core/packages.nix
    ./core/hardware.nix
    ./core/monitoring.nix # node_exporter for Prometheus scraping by forge

    # Infrastructure (Cross-cutting operational concerns)
    ./infrastructure/storage.nix # ZFS pool import and management
    ./infrastructure/nfs.nix # NFS exports for forge
    ./infrastructure/zfs-receive.nix # ZFS replication receiver configuration

    # Secrets
    ./secrets.nix
  ];

  # =============================================================================
  # Host Identity
  # =============================================================================

  networking.hostName = "nas-1";
  networking.hostId = "dc0b510c"; # From Ubuntu machine-id

  # =============================================================================
  # ZFS Configuration
  # =============================================================================

  # Import the existing backup pool (RAIDZ1 with 4x14TB HDDs)
  # This pool is NOT managed by disko - it exists from the Ubuntu installation
  boot.zfs.extraPools = [ "backup" ];

  # Force import of pools that were previously used by another system
  # Required after migration from Ubuntu since hostid changed
  boot.zfs.forceImportAll = true;

  # =============================================================================
  # Impermanence
  # =============================================================================

  # Enable root rollback on boot - root filesystem resets to blank snapshot
  # Persistent data lives in /persist (rpool/safe/persist)
  modules.system.impermanence.enable = true;

  # NAS-specific persistence (in addition to core system paths)
  modules.system.impermanence.directories = [
    "/var/lib/tailscale" # Tailscale machine state
  ];

  # SOPS age key for secret decryption
  modules.system.impermanence.files = [
    "/var/lib/sops-nix/key.txt"
  ];

  # =============================================================================
  # SSH Server
  # =============================================================================

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };

  # =============================================================================
  # Tailscale
  # =============================================================================

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };

  # =============================================================================
  # System State Version
  # =============================================================================

  system.stateVersion = "24.11";
}
