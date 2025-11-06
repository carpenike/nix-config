# Authelia SSO Configuration for Forge
#
# This file configures Authelia authentication service following the modular
# design patterns. It provides unified identity across all homelab services.
#
# Setup Steps:
# 1. Generate secrets (see below)
# 2. Add secrets to secrets.sops.yaml
# 3. Create initial users file
# 4. Deploy configuration
# 5. Test authentication flow

{ config, ... }:

{
  config = {
    # Configure Authelia SSO service
    modules.services.authelia = {
      enable = true;
      instance = "main";
      domain = config.networking.domain;
      port = 9091;

      # Use SQLite for simplicity (perfect for homelab)
      storage = {
        type = "sqlite";
        sqlitePath = "/var/lib/authelia-main/db.sqlite3";
      };

      # Memory-based sessions (no Redis needed)
      session = {
        useRedis = false;
        expiration = "12h";  # Long session for convenience
        inactivity = "1h";   # Auto-logout after inactivity
      };

      # Access control policies
      # Default deny, explicit allow per service
      accessControl = {
        defaultPolicy = "deny";

        # Rules are defined per-service using mkAutheliaProtectedService helper
        # See example below for how to protect services
        rules = [
          # Authelia portal itself is public (login page)
          {
            domain = "auth.${config.networking.domain}";
            policy = "bypass";
          }
        ];
      };

      # OIDC provider for services that support it
      # Disabled until we have actual clients configured
      oidc = {
        enable = false;
        issuerUrl = "https://auth.${config.networking.domain}";

        # Example OIDC clients (add more as needed)
        clients = [
          # Uncomment and configure when ready:
          # {
          #   id = "grafana";
          #   description = "Grafana Dashboards";
          #   secretFile = config.sops.secrets."authelia/oidc/grafana".path;
          #   redirectUris = [
          #     "https://grafana.${config.networking.domain}/login/generic_oauth"
          #   ];
          #   scopes = [ "openid" "profile" "email" "groups" ];
          # }
        ];
      };

      # Email notifier for 2FA registration and password resets
      notifier = {
        type = "smtp";
        smtp = {
          host = "smtp.mailgun.org";
          port = 587;
          username = "authelia@holthome.net";
          passwordFile = config.sops.secrets."authelia/smtp_password".path;
          sender = "Authelia <authelia@holthome.net>";
          subject = "[Authelia] {title}";
        };
      };

      # SOPS-managed secrets
      secrets = {
        jwtSecretFile = config.sops.secrets."authelia/jwt_secret".path;
        sessionSecretFile = config.sops.secrets."authelia/session_secret".path;
        storageEncryptionKeyFile = config.sops.secrets."authelia/storage_encryption_key".path;
        oidcHmacSecretFile = config.sops.secrets."authelia/oidc/hmac_secret".path;
        oidcIssuerPrivateKeyFile = config.sops.secrets."authelia/oidc/issuer_private_key".path;
      };

      # Reverse proxy configuration
      reverseProxy = {
        enable = true;
        hostName = "auth.${config.networking.domain}";
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = 9091;
        };
        security = {
          hsts = {
            enable = true;
            maxAge = 15552000;
            includeSubDomains = true;
          };
          customHeaders = {
            "X-Frame-Options" = "DENY";
            "X-Content-Type-Options" = "nosniff";
          };
        };
      };

      # Prometheus metrics
      metrics = {
        enable = true;
        port = 9091;
        path = "/metrics";
        labels = {
          service_type = "authentication";
          exporter = "authelia";
        };
      };

      # Logging integration
      logging = {
        enable = true;
        journalUnit = "authelia-main.service";
        labels = {
          service = "authelia";
          service_type = "authentication";
        };
      };

      # Backup configuration
      backup = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        zfsDataset = "tank/services/authelia";
        tags = [ "authentication" "sso" "authelia" ];
      };

      # Preseed/DR configuration
      preseed = {
        enable = true;
        repositoryUrl = "b2:carpenike-nas-backup/forge";
        passwordFile = config.sops.secrets."restic/password".path;
        environmentFile = config.sops.secrets."restic/r2-prod-env".path;
        restoreMethods = [ "syncoid" "local" "restic" ];
      };

      # Notifications
      notifications = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "Authelia SSO service failed on ${config.networking.hostName}";
      };
    };

    # Users file is managed via SOPS (declared in secrets.nix)
    # The secret is placed at /var/lib/authelia-main/users.yaml automatically
  };
}

# ============================================================================
# SETUP INSTRUCTIONS
# ============================================================================
#
# 1. Generate Secrets
# --------------------
# Run these commands to generate the required secrets:
#
#   # JWT secret (64 random characters)
#   openssl rand -base64 64
#
#   # Session secret (64 random characters)
#   openssl rand -base64 64
#
#   # Storage encryption key (64 random characters)
#   openssl rand -base64 64
#
#   # OIDC HMAC secret (64 random characters)
#   openssl rand -base64 64
#
#   # OIDC issuer private key (RSA 4096)
#   openssl genrsa 4096
#
# 2. Add Secrets to SOPS
# -----------------------
# Edit hosts/forge/secrets.sops.yaml and add:
#
#   authelia:
#     jwt_secret: "<output from step 1>"
#     session_secret: "<output from step 1>"
#     storage_encryption_key: "<output from step 1>"
#     oidc:
#       hmac_secret: "<output from step 1>"
#       issuer_private_key: |
#         -----BEGIN RSA PRIVATE KEY-----
#         <output from step 1>
#         -----END RSA PRIVATE KEY-----
#
# 3. Generate User Password Hash
# -------------------------------
#   nix-shell -p authelia
#   authelia crypto hash generate argon2 --password 'your-secure-password'
#
# 4. Add Users File to SOPS
# --------------------------
# Edit hosts/forge/secrets.sops.yaml and add:
#
#   authelia:
#     # ... other secrets ...
#     users.yaml: |
#       users:
#         ryan:
#           displayname: "Ryan"
#           password: "$argon2id$v=19$m=65536,t=3,p=4$<your-hash-here>"
#           email: ryan@holthome.net
#           groups:
#             - admins
#             - users
#
# See authelia-users-template.yaml for complete example
#
# 5. Deploy Configuration
# ------------------------
#   nixos-rebuild switch --flake .#forge
#
# 6. Test Authentication
# -----------------------
#   - Visit https://auth.holthome.net
#   - Login with username: ryan, password: your-secure-password
#   - Configure 2FA (recommended)
#
# 7. Protect Services with Authelia
# ----------------------------------
# Example: Protect Prometheus with 2FA
#
# In your service configuration, use the helper:
#
#   let
#     caddyHelpers = import ../../../lib/caddy-helpers.nix { inherit lib; };
#   in {
#     config = caddyHelpers.mkAutheliaProtectedService {
#       name = "prometheus";
#       subdomain = "prometheus";
#       port = 9090;
#       require2FA = true;
#       allowedGroups = [ "admins" ];
#     };
#   }
#
# This will:
#   - Register the service with Caddy
#   - Configure forward auth to Authelia
#   - Add access control rule requiring 2FA for admins group
#
# ============================================================================
