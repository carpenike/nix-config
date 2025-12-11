# hosts/nas-0/core/users.nix
#
# User configuration for nas-0
#
# Minimal users: root, ryan (admin), zfs-replication (for syncoid to nas-1)

{ config, ... }:

{
  # =============================================================================
  # Primary Admin User
  # =============================================================================

  users.users.ryan = {
    isNormalUser = true;
    description = "Ryan";
    extraGroups = [
      "wheel" # sudo/doas access
      "users"
    ];

    # SSH keys are managed globally via home-manager or modules
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwzVnOyiwuGBMgaTp8dLnfvuN3VCdBvOXDN0B5UZLAE ryan@holthome.net"
    ];
  };

  # =============================================================================
  # ZFS Replication User (for syncoid to nas-1)
  # =============================================================================

  # This user is used to SEND snapshots to nas-1 for off-site backup
  # Note: This is the reverse of nas-1's zfs-replication user which RECEIVES
  users.users.zfs-replication = {
    isSystemUser = true;
    group = "zfs-replication";
    home = "/var/lib/zfs-replication";
    createHome = true;
    # IMPORTANT: Needs a working shell for syncoid (NOT nologin!)
    shell = "/run/current-system/sw/bin/bash";
    description = "ZFS replication sender user";
    # SSH key will be created/managed via SOPS for connecting to nas-1
  };

  users.groups.zfs-replication = { };

  # =============================================================================
  # Doas Configuration (repo uses doas instead of sudo)
  # =============================================================================

  # Doas is configured globally via modules/nixos/doas.nix
  # No additional configuration needed here

  # =============================================================================
  # Root User
  # =============================================================================

  users.users.root.openssh.authorizedKeys.keys = config.users.users.ryan.openssh.authorizedKeys.keys;
}
