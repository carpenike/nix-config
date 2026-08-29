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

  # Caddy Security tokens are issued by the hostname that handles the callback.
  # Keep them host-only so one app cannot reuse another app's issuer-bound token.
  # Rotated names make browsers ignore legacy .holthome.net AUTHP_* cookies.
  portalExtraConfig = ''
    set session_id cookie name AUTHP_HOST_SESSION_ID
    set redirect_url cookie name AUTHP_HOST_REDIRECT_URL
    set sandbox_id cookie name AUTHP_HOST_SANDBOX_ID
    set id_token cookie name AUTHP_HOST_ID_TOKEN
    set access_token cookie name AUTHP_HOST_ACCESS_TOKEN
    set refresh_token cookie name AUTHP_HOST_REFRESH_TOKEN

    ${portalTransforms}
  '';
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
          # Client ID Metadata Documents (CIMD), required for the Claude mobile
          # connector to reach whiskeywhiskeywhiskey.org/api/mcp. An EMPTY
          # allowlist (the default) disables metadata-document clients and makes
          # discovery advertise `client_id_metadata_document_supported: false`,
          # which sends Claude down the Dynamic Client Registration path that
          # Pocket ID does not implement.
          #
          # Scoped to the /oauth/ subtree deliberately, NOT `https://claude.ai/**`:
          # published Claude artifacts are served under claude.ai/code/artifact/...,
          # so a whole-origin wildcard would let a crafted artifact register itself
          # as an OAuth client. `**` is a globstar and crosses path segments; a
          # single `*` would not.
          CIMD_URL_ALLOWLIST = ''["https://claude.ai/oauth/**"]'';
          # Self-service email one-time access: the login page offers
          # "email me a login link", which lands the user on /lc/<token>.
          # Upstream-rate-limited (3 requests per 10 min) and it delivers
          # through the SMTP config already set here.
          #
          # Required by the Whiskey crew-auth flow (whiskey-whiskey-whiskey
          # docs/CREW_AUTH_PLAN.md § Recovery): SESSION_DURATION is 60
          # minutes, so a crew member who SKIPS passkey registration during
          # signup needs an emailed link at nearly every future login, not
          # just after losing a device. Without this they are locked out
          # and the host is the help desk.
          #
          # INSTANCE-WIDE: this affects every user of all ~30 clients here,
          # not just the bunker's. Assessed and accepted — accounts still
          # only reach clients their groups allow, the endpoint is rate
          # limited, and the admin-issued variant
          # (EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED) was already on.
          #
          # Note the app config on this instance is DECLARATIVE
          # (UI_CONFIG_DISABLED above): the API and the admin UI both
          # refuse config writes, so this env var is the only way to set
          # it. See network-config docs/pocketid-site-holthome.md.
          EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED = true;

          FILE_BACKEND = "filesystem"; # Required to be "filesystem", "database", or "s3" in v1.16.0+
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
      modules.storage.datasets.services.pocketid.protection = {
        class = "critical";
        objectives = {
          onsiteRpoSeconds = 900;
          offsiteRpoSeconds = 86400;
          rtoSeconds = 7200;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "offsite-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "pocketid-sqlite";
        allowEmptyBootstrap = false;
      };

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
