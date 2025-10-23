{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.node-exporter;
  # TODO: Re-enable shared types once nix store path issues are resolved
in
{
  options.modules.services.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port for Node Exporter metrics endpoint";
    };

    # Standardized metrics collection pattern (simplified)
    metrics = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = {
        enable = true;
        port = 9100;
        path = "/metrics";
        labels = {
          service_type = "system_monitoring";
          exporter = "node";
          collector = "system";
        };
      };
      description = "Prometheus metrics collection configuration";
    };

    # Standardized reverse proxy integration (simplified)
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Reverse proxy configuration for Node Exporter metrics endpoint";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable the underlying Node Exporter service
    services.prometheus.exporters.node = {
      enable = true;
      inherit (cfg) port;
    };

    # Auto-register with Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.node-exporter = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName or "node-exporter.${config.networking.domain}";
      backend = cfg.reverseProxy.backend or {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };
      auth = cfg.reverseProxy.auth or null;
      security = (cfg.reverseProxy.security or {}) // {
        customHeaders = (cfg.reverseProxy.security.customHeaders or {}) // {
          # Additional security for metrics endpoints
          "X-Frame-Options" = "DENY";
          "X-Content-Type-Options" = "nosniff";
          "Referrer-Policy" = "strict-origin-when-cross-origin";
        };
      };
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # Metrics auto-registration happens automatically via observability module
    # No manual Prometheus configuration needed

    # Open firewall for local access (reverse proxy handles external access)
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
