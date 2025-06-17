{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # Python - daily driver
    python311
    python311Packages.pip
    python311Packages.black
    python311Packages.flake8
    python311Packages.ipython

    # Node.js - daily driver
    nodejs
    nodePackages.npm
    nodePackages.yarn

    # Go - daily driver
    go
    gopls
    gotools

    # Other language tools
    rustup
  ];
}
