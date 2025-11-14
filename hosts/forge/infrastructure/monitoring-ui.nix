# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with basic authentication from SOPS secrets.

{ config, pkgs, ... }:

{
  # Expose Prometheus UI on subdomain with SSO protection
  modules.services.caddy.virtualHosts."prometheus" = {
    enable = true;
    hostName = "prometheus.forge.holthome.net";

    # Structured backend configuration
    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9090;
    };

    # Authelia SSO protection (passwordless WebAuthn)
    authelia = {
      enable = true;
      instance = "main";
      autheliaHost = "127.0.0.1";
      autheliaPort = 9091;
      autheliaScheme = "http";
      authDomain = "auth.holthome.net";
      policy = "one_factor";  # Allow passwordless with passkey
      allowedGroups = [ "admins" ];
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

  # Expose Alertmanager UI on subdomain with SSO protection
  modules.services.caddy.virtualHosts."alertmanager" = {
    enable = true;
    hostName = "alertmanager.forge.holthome.net";

    # Structured backend configuration
    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9093;
    };

    # Authelia SSO protection (passwordless WebAuthn)
    authelia = {
      enable = true;
      instance = "main";
      autheliaHost = "127.0.0.1";
      autheliaPort = 9091;
      autheliaScheme = "http";
      authDomain = "auth.holthome.net";
      policy = "one_factor";  # Allow passwordless with passkey
      allowedGroups = [ "admins" ];
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

  # Register Prometheus with Authelia access control
  modules.services.authelia.accessControl.declarativelyProtectedServices.prometheus = {
    domain = "prometheus.forge.holthome.net";
    policy = "one_factor";
    subject = [ "group:admins" ];
    bypassResources = [];
  };

  # Register Alertmanager with Authelia access control
  modules.services.authelia.accessControl.declarativelyProtectedServices.alertmanager = {
    domain = "alertmanager.forge.holthome.net";
    policy = "one_factor";
    subject = [ "group:admins" ];
    bypassResources = [];
  };

  # Note: Monitoring UIs now use Authelia SSO instead of basic auth
  # The monitoring/basic-auth-password secret can be removed after successful migration
}
