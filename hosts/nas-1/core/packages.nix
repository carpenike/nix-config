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
    # Replication receive helpers: syncoid on the sender (forge, nas-0) only
    # compresses (lzop) and buffers (mbuffer) a stream when the tools exist on
    # BOTH ends; otherwise it warns and falls back to an uncompressed,
    # unbuffered transfer. The sender side gets them from syncoid's wrapper.
    lzop
    mbuffer

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
