# hosts/nas-1/core/users.nix
#
# User configuration for nas-1
# Minimal users: root, ryan (admin), zfs-replication (for syncoid)

{ config, lib, ... }:

{
  # =============================================================================
  # Admin User
  # =============================================================================

  users.users.ryan = {
    isNormalUser = true;
    description = "Ryan";
    extraGroups = [ "wheel" "networkmanager" ];
    # Use same SSH key pattern as forge - read from shared ssh.pub file
    # Filter out empty strings that result from trailing newlines
    openssh.authorizedKeys.keys = builtins.filter (k: k != "") (lib.strings.splitString "\n" (builtins.readFile ../../../home/ryan/config/ssh/ssh.pub));
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
      # SSH keys from hosts that replicate TO nas-1
      # Security restrictions applied, but NO forced command (syncoid needs multiple commands)

      # forge -> nas-1 replication
      "no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge"

      # nas-0 -> nas-1 replication
      "no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGqQ7u2OJmATpxitJn2gZJrz+aKlaQJG9iaGW9uc/Lhp zfs-replication@nas-0"
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
