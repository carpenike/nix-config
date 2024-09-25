{ lib, config, pkgs, ... }:
let
  cfg = config.modules.services.bind;
in
{
 # environment.systemPackages = with pkgs; [ bind ];
  options.modules.services.bind = {
    enable = lib.mkEnableOption "bind";
    package = lib.mkPackageOption pkgs "bind" { };
    config = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.resolvconf.useLocalResolver = lib.mkForce false;
    # Clean up journal files
    systemd.services.bind = {
      preStart = lib.mkAfter ''
        rm -rf ${config.services.bind.directory}/*.jnl
      '';
    };
    services.bind = {
      enable = true;
      ipv4Only = true;
      config = import ./config/bind-config.nix {inherit config;};
    };
  };
}
