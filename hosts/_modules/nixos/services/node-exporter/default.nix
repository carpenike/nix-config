{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.node-exporter;
in
{
  options.modules.services.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";
    port = lib.mkOption {
      type = lib.types.int;
      default = 9100;
    };

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for Node Exporter";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "metrics";
        description = "Subdomain to use for the reverse proxy";
      };
      requireAuth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to require authentication (recommended for metrics endpoints)";
      };
      auth = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              default = "metrics";
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = lib.mkOption {
              type = lib.types.str;
              description = "Name of environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Authentication configuration for metrics endpoint";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      inherit (cfg) port;
    };

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.modules.services.caddy.domain or config.networking.domain or "holthome.net"}";
      proxyTo = "localhost:${toString cfg.port}";
      httpsBackend = false; # Node exporter uses HTTP
      auth = lib.mkIf (cfg.reverseProxy.requireAuth && cfg.reverseProxy.auth != null) cfg.reverseProxy.auth;
      extraConfig = ''
        # Metrics endpoint - add security headers
        header / {
          X-Frame-Options "DENY"
          X-Content-Type-Options "nosniff"
          Referrer-Policy "strict-origin-when-cross-origin"
        }
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
