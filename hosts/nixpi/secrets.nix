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

        # AdGuardHome web UI password: NOT declared - the key does not exist
        # in secrets.sops.yaml yet, and sops-nix fails the BUILD for missing
        # keys. The DNS instance runs without a declarative admin user until
        # then (UI is loopback-only). MANUAL STEP to enable auth:
        #   1. sops hosts/nixpi/secrets.sops.yaml  ->  add
        #      networking/adguardhome/password (same value as luna's)
        #   2. Uncomment this block, then remove `passwordSecret = null` and
        #      the `users = [ ]` override in ./dns.nix.
        # "networking/adguardhome/password" = {
        #   restartUnits = [ "adguardhome.service" ];
        #   owner = "adguardhome";
        # };

        # TODO: Add cloudflare secrets when needed
        # "cloudflare/dns_api_token" = {
        #   owner = config.services.caddy.user;
        # };
        # "cloudflared/credentials" = {};
      };
    };
  };
}
