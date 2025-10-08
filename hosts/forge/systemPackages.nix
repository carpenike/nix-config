{ pkgs, ... }:
{
  environment.systemPackages = [
    # Basic system packages
    pkgs.vim
    pkgs.git
    pkgs.htop
    pkgs.tmux
    pkgs.wget
    pkgs.curl

    # ZFS utilities
    pkgs.zfs

    # TODO: Add more packages as needed
    # You can copy patterns from luna's systemPackages.nix when ready
  ];
}
