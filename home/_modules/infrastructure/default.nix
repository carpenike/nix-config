{ pkgs, lib, config, ... }:
let
  cfg = config.modules.infrastructure;
in
{
  # Gated so appliance hosts (e.g. nixpi) can opt out of the heavy cloud/infra
  # CLIs. Defaults to true to preserve existing behaviour on workstation hosts.
  options.modules.infrastructure.enable =
    lib.mkEnableOption "cloud / infrastructure CLI tools (azure-cli, terraform, talosctl, lima, cloudflared)"
    // { default = true; };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Cloud infrastructure tools
      azure-cli
      cloudflared

      # Kubernetes cluster management
      talosctl
      # talhelper - not in nixpkgs, needs custom package or homebrew

      # Container tools
      pkgs.unstable.lima

      # Other infrastructure tools
      terraform
      # packer  # temporarily disabled - segfaults building from source on aarch64-darwin
    ];
  };
}
