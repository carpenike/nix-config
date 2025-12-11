# hosts/nas-0/core/packages.nix
#
# System packages for nas-0
# Minimal set appropriate for a NAS/storage server

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Core utilities
    vim
    git
    htop
    tmux

    # Network diagnostics
    curl
    wget
    dig
    tcpdump

    # Storage tools
    smartmontools # SMART monitoring (critical for 28 drives)
    hdparm # Drive parameters
    lsof # Open files
    iotop # I/O monitoring

    # ZFS tools (zfs package is included by boot.zfs)
    sanoid # Snapshot management (service also enabled)

    # NFS debugging
    nfs-utils
  ];

  # Enable command-not-found for convenience
  programs.command-not-found.enable = true;
}
