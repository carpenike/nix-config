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

        # AdGuardHome web UI password (bcrypt-hashed into AdGuardHome.yaml by
        # the module's preStart; see modules/nixos/services/adguardhome).
        # MANUAL STEP: this key does not exist in secrets.sops.yaml yet - add it
        # with `sops hosts/nixpi/secrets.sops.yaml` (same value as luna's) or
        # adguardhome.service will fail to decrypt on activation.
        "networking/adguardhome/password" = {
          restartUnits = [ "adguardhome.service" ];
          owner = "adguardhome";
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
