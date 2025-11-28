# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with PocketID/OIDC authentication via caddy-security.
#
# API access from internal networks is allowed without authentication to support
# CLI tools like `backup-status` that query Prometheus metrics.

{ config, pkgs, ... }:

let
  # RFC 1918 private network ranges for internal API access
  internalNetworks = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
in
{
  # Expose Prometheus UI on subdomain with Pocket ID + caddy-security protection
  modules.services.caddy.virtualHosts."prometheus" = {
    enable = true;
    hostName = "prometheus.forge.holthome.net";

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

      # Allow API access from internal networks without authentication
      # This enables CLI tools (e.g., backup-status) to query Prometheus metrics
      # Only the specific query endpoints needed by backup-status are bypassed
      # Note: Caddy matcher requires BOTH path match AND internal network - see caddy/default.nix
      bypassResources = [
        "^/api/v1/query$"       # Instant query endpoint
        "^/api/v1/query_range$" # Range query endpoint
      ];
      allowedNetworks = internalNetworks;
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
  # Note: No API bypass configured - Alertmanager is only accessed through the web UI.
  # CLI tools (backup-status) only query Prometheus, not Alertmanager.
  modules.services.caddy.virtualHosts."alertmanager" = {
    enable = true;
    hostName = "alertmanager.forge.holthome.net";

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
