# hosts/nas-1/services/attic.nix
#
# Attic Binary Cache Server
#
# Provides a Nix binary cache for the homelab, accelerating builds
# by caching build artifacts locally.
#
# Access: https://attic.holthome.net
# Data: /var/lib/atticd (persisted via impermanence)

{ config, ... }:

{
  modules.services = {
    attic = {
      enable = true;
      listenAddress = "127.0.0.1:8080";
      jwtSecretFile = config.sops.secrets."attic/jwt-secret".path;

      reverseProxy = {
        enable = true;
        hostName = "attic.holthome.net";
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = 8080;
        };
      };

      autoPush = {
        enable = true;
        cacheName = "homelab";
      };
    };

    # Enable attic admin tools
    attic-admin.enable = true;
  };

  # Persist attic data across reboots (impermanence)
  modules.system.impermanence.directories = [
    {
      directory = "/var/lib/atticd";
      user = "attic";
      group = "attic";
      mode = "0755";
    }
  ];
}
