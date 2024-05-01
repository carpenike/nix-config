{ pkgs, ... }:
{
  # Collection of useful CLI apps
  home.packages = with pkgs; [
    # Command Line
    disfetch lolcat cowsay
    starfetch
    cava
    killall
    libnotify
    timer
    brightnessctl
    gnugrep
    bat eza fd bottom ripgrep
    rsync
    unzip
    w3m
    pandoc
    hwinfo
    pciutils
    numbat
    vim neovim
  ];
}
