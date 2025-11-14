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
}
