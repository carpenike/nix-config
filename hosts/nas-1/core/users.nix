# hosts/nas-1/core/users.nix
#
# User configuration for nas-1
# Minimal users: root, ryan (admin), zfs-replication (for syncoid)

{ config, ... }:

{
  # =============================================================================
  # Admin User
  # =============================================================================

  users.users.ryan = {
    isNormalUser = true;
    description = "Ryan";
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      # TODO: Add your SSH public key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINhGpVG0XMvWLgKXfvhHMNcu6v+nokkz7WjyLyVcDLLG ryan@holthome.net"
    ];
  };

  # =============================================================================
  # ZFS Replication User
  # =============================================================================

  # This user receives ZFS snapshots from forge via syncoid
  users.users.zfs-replication = {
    isSystemUser = true;
    group = "zfs-replication";
    home = "/var/lib/zfs-replication";
    createHome = true;
    # IMPORTANT: Needs a working shell for syncoid (NOT nologin!)
    shell = "/run/current-system/sw/bin/bash";
    description = "ZFS replication receiver user";
    openssh.authorizedKeys.keys = [
      # SSH key from forge's zfs-replication user
      # Security restrictions applied, but NO forced command (syncoid needs multiple commands)
      "no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge"
    ];
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
