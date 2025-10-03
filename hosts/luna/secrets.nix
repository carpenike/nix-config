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
        "networking/bind/externaldns-key" = {
          restartUnits = [ "bind.service" ];
          owner = config.users.users.named.name;
        };
        "networking/bind/ddnsupdate-key" = {
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
        "reverse-proxy/metrics-auth" = {
          restartUnits = [ "caddy.service" ];
        };
        "reverse-proxy/vault-auth" = {
          restartUnits = [ "caddy.service" ];
        };
        "reverse-proxy/glances-auth" = {
          restartUnits = [ "caddy.service" ];
        };
        "networking/adguardhome/password" = {
          restartUnits = [ "adguardhome.service" ];
          owner = "adguardhome";
        };
        "attic/jwt-secret" = {
          restartUnits = [ "atticd.service" ];
          owner = "attic";
        };
        "attic/admin-token" = {
          mode = "0444";
        };

        # Backup system secrets
        "backup/restic-password" = {
          mode = "0400";
          owner = "root";
        };
        "backup/b2-application-key-id" = {
          mode = "0400";
          owner = "root";
        };
        "backup/b2-application-key" = {
          mode = "0400";
          owner = "root";
        };
        "backup/healthchecks-uuid" = {
          mode = "0444";
        };
        "backup/ntfy-topic" = {
          mode = "0444";
        };
        "backup/unifi/mongo-credentials" = {
          mode = "0400";
          owner = "root";
        };
      };

      # SOPS templates for backup environment files
      templates = {
        "restic-primary.env" = {
          content = ''
            RESTIC_REPOSITORY=/mnt/nas/backups/luna
            RESTIC_PASSWORD_FILE=${config.sops.secrets."backup/restic-password".path}
          '';
          owner = "root";
          group = "root";
          mode = "0400";
        };

        "restic-cloud.env" = {
          content = ''
            RESTIC_REPOSITORY=b2:homelab-backups:/luna
            RESTIC_PASSWORD_FILE=${config.sops.secrets."backup/restic-password".path}
            B2_ACCOUNT_ID=${config.sops.placeholder."backup/b2-application-key-id"}
            B2_ACCOUNT_KEY=${config.sops.placeholder."backup/b2-application-key"}
          '';
          owner = "root";
          group = "root";
          mode = "0400";
        };

        "backup-monitoring.env" = {
          content = ''
            HEALTHCHECKS_UUID=${config.sops.placeholder."backup/healthchecks-uuid"}
            NTFY_TOPIC=${config.sops.placeholder."backup/ntfy-topic"}
          '';
          owner = "root";
          group = "root";
          mode = "0444";
        };

        "unifi-mongo-credentials" = {
          content = config.sops.placeholder."backup/unifi/mongo-credentials";
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };
    };
  };
}
