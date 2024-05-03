{
  pkgs,
  config,
  ...
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
        onepassword-credentials = {
          mode = "0444";
        };
        "networking/cloudflare/ddns/apiToken" = {};
        "networking/cloudflare/ddns/records" = {};
        "networking/bind/rndc-key" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
        "networking/bind/ddnsupdate-key" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
        "networking/bind/externaldns-key" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
        "networking/bind/zones/holthome.net" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
        "networking/bind/zones/10.in-addr.arpa" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
      };
    };
  };
}