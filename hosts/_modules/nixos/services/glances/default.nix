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
      description = "Port for Glances web interface (binds to localhost only)";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--disable-plugin" "docker" ];
      description = "Extra command-line arguments for the glances command";
    };

    resources = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        MemoryMax = "256M";
        CPUQuota = "30%";
      };
      description = "Resource limits for the Glances systemd service";
    };

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for Glances";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        description = "Subdomain for the reverse proxy (defaults to system hostname for per-host monitoring)";
      };
      auth = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              default = "admin";
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = lib.mkOption {
              type = lib.types.str;
              description = "Name of environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Authentication configuration (required for secure access - Glances has no built-in auth)";
      };
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
        ExecStart = "${pkgs.glances}/bin/glances -w --bind 127.0.0.1 --port ${toString cfg.port} ${lib.escapeShellArgs cfg.extraArgs}";
        Restart = "always";
        User = "glances";
        Group = "glances";

        # Security Hardening
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;

        # Resource Limits
        MemoryMax = cfg.resources.MemoryMax;
        CPUQuota = cfg.resources.CPUQuota;
      };
    };

    # Create user for glances
    users.users.glances = {
      isSystemUser = true;
      group = "glances";
    };

    users.groups.glances = {};

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf (cfg.reverseProxy.enable && config.modules.services.caddy.enable) {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";
      proxyTo = "localhost:${toString cfg.port}";
      httpsBackend = false; # Glances uses HTTP locally
      auth = cfg.reverseProxy.auth;
      extraConfig = ''
        # Required for Glances WebSocket support (real-time updates)
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}

        # Security headers for monitoring interface
        header / {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
        }
      '';
    };
  };
}
