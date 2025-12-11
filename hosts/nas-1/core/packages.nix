# hosts/nas-1/core/packages.nix
#
# System packages for nas-1
# Minimal set for a NAS/backup appliance

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Core utilities
    vim
    htop
    tmux
    git

    # Networking
    curl
    wget
    dig
    tcpdump

    # ZFS utilities
    zfs

    # Monitoring
    iotop
    lsof
    pv

    # File management
    rsync
    tree
    ncdu
  ];
}
