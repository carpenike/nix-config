# Decrypted with the host's SSH key (/etc/ssh/ssh_host_ed25519_key), whose
# age recipient is &mx-edge in .sops.yaml. The values come from 1Password
# item mx-edge (vault k8s-secrets).
{ config, ... }:
{
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      # One-time, pre-approved key tagged tag:mx-edge. Used only for the
      # first `tailscale up`; the node key persists in /var/lib/tailscale.
      "tailscale/auth_key" = { };
      "stalwart/admin_password" = { };
      # Zone Read + DNS Edit on holthome.net only: ACME DNS-01 for the MX
      # certificate. Not the cluster's token.
      "stalwart/cloudflare_api_token" = { };
    };
    # Read by the Stalwart container as environment variables
    # (EnvironmentVariable sources in its settings).
    templates."stalwart.env".content = ''
      STALWART_RECOVERY_ADMIN=admin:${config.sops.placeholder."stalwart/admin_password"}
      STALWART_CLOUDFLARE_TOKEN=${config.sops.placeholder."stalwart/cloudflare_api_token"}
    '';
  };
}
