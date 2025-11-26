{ config, lib, pkgs, ... }:
let
  inherit (lib) mkMerge mkDefault;
  inherit (config.networking) domain;

  # Use a distinct hostname while Authelia still occupies auth.<domain>
  serviceDomain = "id.${domain}";
  dataset = "tank/services/pocketid";
  dataDir = "/var/lib/pocket-id";
  pocketIdPort = 1411;
  metricsPort = 9464;

  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/pocketid";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";

  caddyClientSecretEnvVar = "CADDY_SECURITY_POCKETID_CLIENT_SECRET";
  metadataUrl = "https://${serviceDomain}/.well-known/openid-configuration";
  internalAppUrl = "https://${serviceDomain}";

  authenticatedTransform = ''
    transform user {
      match realm forge-pocketid
      action add role authenticated
    }
  '';

  portalExtraConfig = authenticatedTransform;
  serviceEnabled = config.modules.services.pocketid.enable;
in
{
  config = mkMerge [
    {
      modules.services.pocketid = {
        enable = true;
        package = pkgs.unstable.pocket-id;
        dataDir = dataDir;
        publicUrl = "https://${serviceDomain}";
        environmentFile = config.sops.secrets."pocketid/environment".path;
        listen = {
          address = "127.0.0.1";
          port = pocketIdPort;
        };
        database.backend = "sqlite";
        extraSettings = {
          INTERNAL_APP_URL = internalAppUrl;
          LOG_LEVEL = "info";
          LOG_JSON = true;
          METRICS_ENABLED = true;
          UI_CONFIG_DISABLED = true;
          FILE_BACKEND = "fs";
          UPLOAD_PATH = "${dataDir}/uploads";
          KEYS_STORAGE = "database";
          KEYS_PATH = "${dataDir}/keys";
          ENCRYPTION_KEY_FILE = toString config.sops.secrets."pocketid/encryption_key".path;
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = pocketIdPort;
          };
          security = {
            hsts = {
              enable = true;
              maxAge = 15552000;
              includeSubDomains = true;
              preload = false;
            };
            customHeaders = {
              "X-Frame-Options" = "DENY";
              "X-Content-Type-Options" = "nosniff";
            };
          };
        };

        metrics = {
          enable = true;
          port = metricsPort;
          interface = "127.0.0.1";
          labels = {
            service = "pocket-id";
            service_type = "identity";
            exporter = "otel";
          };
        };

        backup = {
          enable = true;
          repository = "nas-primary";
          zfsDataset = dataset;
          tags = [ "identity" "pocketid" "sqlite" ];
        };

        smtp = {
          enable = true;
          host = "smtp.mailgun.org";
          port = 587;
          fromAddress = "auth@holthome.net";
          username = "auth@holthome.net";
          passwordFile = config.sops.secrets."pocketid/smtp_password".path;
          tlsMode = "starttls";
          skipCertVerify = false;
          sendLoginNotifications = true;
          sendAdminOneTimeCodes = true;
          sendApiKeyExpiry = true;
          allowUnauthenticatedOneTimeCodes = false;
        };
      };

    }

    (lib.mkIf serviceEnabled {
      modules.alerting.rules."pocketid-service-down" = {
        type = "promql";
        alertname = "PocketIDServiceDown";
        expr = ''systemd_unit_state{name="pocket-id.service",state="active"} == 0'';
        for = "2m";
        severity = "critical";
        labels = {
          service = "pocket-id";
          category = "availability";
        };
        annotations = {
          summary = "Pocket ID service is unavailable on {{ $labels.instance }}";
          description = "pocket-id.service is not active. Users cannot authenticate with passkeys or OIDC.";
          command = "journalctl -u pocket-id -n 200";
        };
      };

      modules.services.caddy.virtualHosts.pocketid.cloudflare = {
        enable = true;
        tunnel = "forge";
      };

      modules.services.caddy.security = {
        enable = mkDefault true;

        identityProviders.pocketid = {
          driver = "generic";
          realm = "forge-pocketid";
          clientId = "caddy-security";
          clientSecretEnvVar = caddyClientSecretEnvVar;
          scopes = [ "openid" "profile" "email" "groups" ];
          baseAuthUrl = "https://${serviceDomain}";
          metadataUrl = metadataUrl;
        };

        authenticationPortals.pocketid = {
          identityProviders = [ "pocketid" ];
          cookie = {
            insecure = false;
            domain = ".${domain}";
          };
          extraConfig = portalExtraConfig;
        };

        authorizationPolicies = {
          default = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "authenticated" ];
          };

          admins = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "admins" ];
          };

          media = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "media" ];
          };

          lan-only = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "automation" ];
          };
        };
      };
    })

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = replicationTargetHost;
          targetDataset = replicationTargetDataset;
          hostKey = replicationHostKey;
          sendOptions = "wp";
          recvOptions = "u";
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })
  ];
}
