{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.glances;
in
{
  options.modules.services.glances = {
    enable = lib.mkEnableOption "Glances system monitoring";

    port = lib.mkOption {
      type = lib.types.port;
      default = 61208;
      description = "Port for Glances web interface";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the firewall for Glances";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install glances
    environment.systemPackages = [ pkgs.glances ];

    # Glances web service
    systemd.services.glances-web = {
      description = "Glances Web Server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.glances}/bin/glances -w --disable-plugin docker";
        Restart = "always";
        User = "glances";
        Group = "glances";
      };
    };

    # Create user for glances
    users.users.glances = {
      isSystemUser = true;
      group = "glances";
    };

    users.groups.glances = {};

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
