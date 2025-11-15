# Cloudflare Tunnel Configuration
# Provides secure external access to selected services via Cloudflare's network
{ config, ... }:
{
  # Enable Cloudflare Tunnel service
  modules.services.cloudflared = {
    enable = true;

    # Define tunnels (can have multiple for different purposes)
    tunnels.forge = {
      # Tunnel UUID from Cloudflare dashboard
      id = "349603ab-49ed-4e49-bb76-6d803d8b978e";

      # Credentials file managed by SOPS (see secrets.nix)
      # To create: cloudflared tunnel create forge
      # Then encrypt the JSON with: sops hosts/forge/secrets.sops.yaml
      credentialsFile = config.sops.secrets."networking/cloudflare/forge-credentials".path;

      # Default backend: route all tunnel traffic through Caddy
      # This preserves all Authelia authentication, security headers, etc.
      defaultService = "http://127.0.0.1:80";

      # Optional: Enable debug logging
      # extraConfig = {
      #   "log-level" = "debug";
      # };
    };
  };

  # Example: Enable external access for a service
  # Uncomment and modify as needed:
  #
  # modules.services.caddy.virtualHosts.grafana = {
  #   # ... existing configuration ...
  #   cloudflare = {
  #     enable = true;
  #     tunnel = "forge";
  #   };
  # };

  # Co-located Service Monitoring
  modules.alerting.rules."cloudflare-tunnel-service-down" = {
    type = "promql";
    alertname = "CloudflareTunnelServiceInactive";
    expr = "container_service_active{name=\"cloudflared\"} == 0";
    for = "2m";
    severity = "critical"; # Critical - external access gateway
    labels = { service = "cloudflare-tunnel"; category = "availability"; };
    annotations = {
      summary = "Cloudflare Tunnel service is down on {{ $labels.instance }}";
      description = "The Cloudflare Tunnel service is not active. External access to homelab services is unavailable.";
      command = "systemctl status cloudflared-tunnel-forge.service";
    };
  };
}
