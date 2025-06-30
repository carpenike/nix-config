{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.caddy;
in
{
  options.modules.services.caddy = {
    enable = lib.mkEnableOption "Caddy web server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.caddy;
      description = "Caddy package to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable the standard NixOS caddy service
    services.caddy = {
      enable = true;
      package = cfg.package;

      # Basic configuration
      globalConfig = ''
        auto_https off
      '';
    };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
