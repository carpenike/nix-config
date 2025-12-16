{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (lib) mkMerge mkDefault;
  inherit (config.networking) domain;

  # Use a distinct hostname while Authelia still occupies auth.<domain>
  serviceDomain = "id.${domain}";
  dataset = "tank/services/pocketid";
  dataDir = "/var/lib/pocket-id";
  pocketIdPort = 1411;
  metricsPort = 9464;

  caddyClientSecretEnvVar = "CADDY_SECURITY_POCKETID_CLIENT_SECRET";
  metadataUrl = "https://${serviceDomain}/.well-known/openid-configuration";
  internalAppUrl = "https://${serviceDomain}";

  # Transform rules for caddy-security portal
  # - 'authenticated' role for general access control
  # - 'authp/user' role for API features
  # NOTE: The settings/profile page requires deploying the separate Profile UI app
  # For now, API key auth uses the local identity store configured above
  portalTransforms = ''
    transform user {
      match realm forge-pocketid
      action add role authenticated
    }

    transform user {
      match realm forge-pocketid
      action add role authp/user
    }
  '';

  portalExtraConfig = portalTransforms;
  serviceEnabled = config.modules.services.pocketid.enable or false;
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
          FILE_BACKEND = "filesystem";  # Required to be "filesystem", "database", or "s3" in v1.16.0+
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

        backup = forgeDefaults.mkBackupWithTags "pocketid" [ "identity" "pocketid" "sqlite" ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

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
      # Service availability alert
      modules.alerting.rules."pocketid-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "pocket-id" "PocketID" "identity provider";

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

        # Local identity store for user-generated API keys
        # Users can generate personal API keys via the portal UI at /settings
        # These keys are stored in a local JSON file and validated via caddy-security
        localIdentityStores.localdb = {
          realm = "local";
          path = "/var/lib/caddy/auth/users.json";
        };

        authenticationPortals.pocketid = {
          identityProviders = [ "pocketid" ];
          # Enable local identity store for user-generated API keys
          identityStores = [ "localdb" ];
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
            # Enable API key authentication via local identity store
            apiKeyAuth = {
              enable = true;
              portal = "pocketid";
              realm = "local";
            };
          };

          admins = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "admins" ];
            apiKeyAuth = {
              enable = true;
              portal = "pocketid";
              realm = "local";
            };
          };

          media = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "media" ];
            apiKeyAuth = {
              enable = true;
              portal = "pocketid";
              realm = "local";
            };
          };

          home = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "home" ];
            apiKeyAuth = {
              enable = true;
              portal = "pocketid";
              realm = "local";
            };
          };

          lan-only = {
            authUrl = "/caddy-security/oauth2/forge-pocketid";
            allowRoles = [ "automation" ];
          };
        };
      };

      # Dataset replication
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "pocketid";
    })
  ];
}
