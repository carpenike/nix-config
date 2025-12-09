{ lib
, mylib
, config
, ...
}:
let
  cfg = config.modules.services.node-exporter;
  # Import shared type definitions
  sharedTypes = mylib.types;
in
{
  options.modules.services.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port for Node Exporter metrics endpoint";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
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

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
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

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };

      # Authentication from shared types
      auth = cfg.reverseProxy.auth;

      # Security configuration with additional headers for metrics endpoints
      security = cfg.reverseProxy.security // {
        customHeaders = cfg.reverseProxy.security.customHeaders // {
          "X-Frame-Options" = "DENY";
          "X-Content-Type-Options" = "nosniff";
          "Referrer-Policy" = "strict-origin-when-cross-origin";
        };
      };

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # Metrics auto-registration happens automatically via observability module
    # No manual Prometheus configuration needed

    # Open firewall for local access (reverse proxy handles external access)
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
