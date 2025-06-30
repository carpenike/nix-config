{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.cloudflared;
in
{
  options.modules.services.cloudflared = {
    enable = lib.mkEnableOption "Cloudflare Tunnel (cloudflared)";

    tunnelName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Name of the Cloudflare tunnel";
    };

    credentialsFile = lib.mkOption {
      type = lib.types.path;
      default = config.sops.secrets."cloudflared/credentials".path;
      description = "Path to the tunnel credentials file";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install cloudflared
    environment.systemPackages = [ pkgs.cloudflared ];

    # Cloudflared tunnel service
    systemd.services.cloudflared = {
      description = "Cloudflare Tunnel";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --credentials-file ${cfg.credentialsFile} ${cfg.tunnelName}";
        Restart = "always";
        RestartSec = "5s";
        User = "cloudflared";
        Group = "cloudflared";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    # Create user for cloudflared
    users.users.cloudflared = {
      isSystemUser = true;
      group = "cloudflared";
      home = "/var/lib/cloudflared";
      createHome = true;
    };

    users.groups.cloudflared = {};
  };
}
