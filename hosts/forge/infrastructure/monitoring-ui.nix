# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with basic authentication from SOPS secrets.

{ config, pkgs, ... }:

{
  # Expose Prometheus UI on subdomain with Pocket ID + caddy-security protection
  modules.services.caddy.virtualHosts."prometheus" = {
    enable = true;
    hostName = "prom.holthome.net";

    # Structured backend configuration
    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9090;
    };

    # Pocket ID via caddy-security authorization
    caddySecurity = {
      enable = true;
      portal = "pocketid";
      policy = "admins";
      claimRoles = [
        {
          claim = "groups";
          value = "admins";
          role = "admins";
        }
      ];

      # Static API key for automation (backup status queries from taskfiles)
      staticApiKeys = [
        {
          name = "backup-taskfile";
          envVar = "PROMETHEUS_BACKUP_API_KEY";
        }
      ];
    };

    # Security headers for web interface
    security.customHeaders = {
      "X-Frame-Options" = "SAMEORIGIN";
      "X-Content-Type-Options" = "nosniff";
      "X-XSS-Protection" = "1; mode=block";
      "Referrer-Policy" = "strict-origin-when-cross-origin";
    };

    # Headers for inside the reverse_proxy block
    reverseProxyBlock = ''
      header_up Host {upstream_hostport}
      header_up X-Real-IP {remote_host}
    '';
  };

  # Expose Alertmanager UI on subdomain with Pocket ID + caddy-security protection
  modules.services.caddy.virtualHosts."alertmanager" = {
    enable = true;
    hostName = "am.holthome.net";

    # Structured backend configuration
    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9093;
    };

    # Pocket ID via caddy-security authorization
    caddySecurity = {
      enable = true;
      portal = "pocketid";
      policy = "admins";
      claimRoles = [
        {
          claim = "groups";
          value = "admins";
          role = "admins";
        }
      ];
    };

    # Security headers for web interface
    security.customHeaders = {
      "X-Frame-Options" = "SAMEORIGIN";
      "X-Content-Type-Options" = "nosniff";
      "X-XSS-Protection" = "1; mode=block";
      "Referrer-Policy" = "strict-origin-when-cross-origin";
    };

    # Headers for inside the reverse_proxy block
    reverseProxyBlock = ''
      header_up Host {upstream_hostport}
      header_up X-Real-IP {remote_host}
    '';
  };

  # Note: Monitoring UIs now use caddy-security + Pocket ID instead of Authelia
}
