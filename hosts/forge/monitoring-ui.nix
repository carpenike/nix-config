# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with basic authentication from SOPS secrets.

{ config, pkgs, ... }:

{
  # Expose Prometheus UI on subdomain with LAN-only access
  modules.reverseProxy.virtualHosts."prometheus" = {
    enable = true;
    hostName = "prometheus.forge.holthome.net";

    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9090;
    };

    # Basic authentication using SOPS secret
    auth = {
      user = "admin";
      passwordHashEnvVar = "MONITORING_BASIC_AUTH_PASSWORD";
    };

    # LAN-only access restriction (internal networks)
    vendorExtensions.caddy.extraConfig = ''
      @lan remote_ip 10.20.0.0/24 10.30.0.0/16
      handle @lan {
        # Allowed
      }
      handle {
        abort
      }
    '';

    securityHeaders = {
      X-Frame-Options = "SAMEORIGIN";
      X-Content-Type-Options = "nosniff";
    };
  };

  # Expose Alertmanager UI on subdomain with LAN-only access
  modules.reverseProxy.virtualHosts."alertmanager" = {
    enable = true;
    hostName = "alertmanager.forge.holthome.net";

    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9093;
    };

    # Basic authentication using SOPS secret
    auth = {
      user = "admin";
      passwordHashEnvVar = "MONITORING_BASIC_AUTH_PASSWORD";
    };

    # LAN-only access restriction (internal networks)
    vendorExtensions.caddy.extraConfig = ''
      @lan remote_ip 10.20.0.0/24 10.30.0.0/16
      handle @lan {
        # Allowed
      }
      handle {
        abort
      }
    '';

    securityHeaders = {
      X-Frame-Options = "SAMEORIGIN";
      X-Content-Type-Options = "nosniff";
    };
  };

  # Load the monitoring basic auth password from SOPS
  sops.secrets."monitoring/basic-auth-password" = {
    sopsFile = ./secrets.sops.yaml;
    restartUnits = [ "caddy.service" ];
  };

  # Pass the secret to Caddy as an environment variable
  systemd.services.caddy.serviceConfig.EnvironmentFile = [
    (pkgs.writeText "caddy-monitoring-auth.env" ''
      MONITORING_BASIC_AUTH_PASSWORD=${config.sops.secrets."monitoring/basic-auth-password".path}
    '')
  ];
}
