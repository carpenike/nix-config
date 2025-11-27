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
        # WiFi passwords
        "wifi/iot_password" = {
          path = "/run/secrets/wifi_iot_password";
        };
        "wifi/rvproblems_password" = {
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
