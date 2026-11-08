# Monitoring UI Exposure Configuration
# Provides LAN-only access to Prometheus and Alertmanager web interfaces
# with Pocket ID SSO + optional static API keys for automation.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  clusterNodes = import ../lib/cluster-nodes.nix;
in
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
        (forgeDefaults.mkStaticApiKey "backup-taskfile" "PROMETHEUS_BACKUP_API_KEY")
      ];

      # The cluster Grafana's Prometheus datasource (carpenike/k8s-gitops
      # docs/grafana.md): GET on the query and metadata API only, and only
      # from the sleds. The UI, the admin and write APIs (admin/tsdb,
      # remote write) and every other peer still need Pocket ID.
      bypassResources = [
        "^/api/v1/(query|query_range|query_exemplars|series|labels|label/[^/]+/values|metadata|status/buildinfo|format_query|rules|alerts)$"
      ];
      bypassMethods = [ "GET" ];
      allowedNetworks = clusterNodes;
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

    # Pocket ID via caddy-security authorization.
    # Cluster Prometheus on 10.20.10.20-23 posts alerts with no API key.
    # The bypass matcher is one AND set: exact path, POST, and those peers.
    # The UI and every other path still use `authorize with admins`.
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
      bypassResources = [ "^/api/v2/alerts$" ];
      bypassMethods = [ "POST" ];
      allowedNetworks = clusterNodes;
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
