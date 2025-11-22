{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # Cloud infrastructure tools
    cloudflared

    # Kubernetes cluster management
    talosctl
    # talhelper - not in nixpkgs, needs custom package or homebrew

    # Container tools
    pkgs.unstable.lima

    # Other infrastructure tools
    terraform
    packer
  ];
}
