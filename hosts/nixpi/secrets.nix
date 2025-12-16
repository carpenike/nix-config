{ pkgs
, config
, ...
}:
{
  config = {
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];

    sops = {
      defaultSopsFile = ./secrets.sops.yaml;
      age.sshKeyPaths = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
      secrets = {
        # WiFi passwords (flat keys matching secrets.sops.yaml)
        "IOT_WIFI_PASSWORD" = {
          path = "/run/secrets/wifi_iot_password";
        };
        "RVPROBLEMS_WIFI_PASSWORD" = {
          path = "/run/secrets/wifi_rvproblems_password";
        };

        # TODO: Add cloudflare secrets when needed
        # "cloudflare/dns_api_token" = {
        #   owner = config.services.caddy.user;
        # };
        # "cloudflared/credentials" = {};
      };
    };
  };
}
