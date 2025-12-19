# hosts/nas-1/secrets.nix
#
# SOPS secrets configuration for nas-1

{ config, ... }:

{
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    age.sshKeyPaths = [
      "/persist/etc/ssh/ssh_host_ed25519_key"
    ];

    secrets = {
      # Attic binary cache JWT secret
      "attic/jwt-secret" = {
        restartUnits = [ "atticd.service" ];
        owner = "attic";
      };

      # Attic admin token for CLI tools
      "attic/admin-token" = {
        mode = "0444";
      };

      # Cloudflare API token for Caddy DNS challenge
      "networking/cloudflare/ddns/apiToken" = {
        restartUnits = [ "caddy.service" ];
      };
    };
  };
}
