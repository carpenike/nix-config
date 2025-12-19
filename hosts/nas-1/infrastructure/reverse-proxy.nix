# hosts/nas-1/infrastructure/reverse-proxy.nix
#
# Caddy reverse proxy configuration for nas-1
#
# Provides HTTPS termination and reverse proxy for services hosted on nas-1.
# Uses Cloudflare DNS challenge for automatic TLS certificate provisioning.

{ config, ... }:

{
  modules.services.caddy = {
    enable = true;
    domain = "holthome.net";
  };

  # Persist Caddy data (ACME certificates) across reboots
  modules.system.impermanence.directories = [
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0750";
    }
  ];

  # Load environment file with Cloudflare API token for ACME DNS challenge
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/run/secrets/rendered/caddy-env";

  # Create environment file from SOPS secrets
  sops.templates."caddy-env" = {
    content = ''
      CLOUDFLARE_API_TOKEN=${config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
    '';
    owner = config.services.caddy.user;
    group = config.services.caddy.group;
  };
}
