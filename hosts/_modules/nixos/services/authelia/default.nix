# Authelia SSO Service Module
#
# This module wraps the native NixOS `services.authelia.instances` and adds
# standardized homelab patterns for storage, backup, monitoring, and integration.
#
# DESIGN RATIONALE:
# Authelia provides a lightweight SSO solution for homelabs with:
#   - Single Go binary (no containers)
#   - SQLite database (no PostgreSQL)
#   - Memory-based sessions (no Redis for small scale)
#   - File-based user management (git-trackable)
#   - Native NixOS integration
#
# This is significantly simpler than Authentik (1 service vs 4+) while providing
# unified identity across all services, centralized 2FA, and granular access control.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkMerge mkEnableOption mkOption mkDefault types;

  # Import storage helpers for preseed service generation
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.authelia;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  instanceName = cfg.instance;
  serviceUnitFile = "authelia-${instanceName}.service";
  dataDir = "/var/lib/authelia-${instanceName}";
  datasetPath = "${storageCfg.datasets.parentDataset}/authelia";

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.authelia = {
    enable = mkEnableOption "Authelia SSO authentication service";

    instance = mkOption {
      type = types.str;
      default = "main";
      description = "Authelia instance name (allows multiple instances)";
    };

    domain = mkOption {
      type = types.str;
      default = config.networking.domain or "holthome.net";
      description = "Base domain for Authelia and protected services";
    };

    port = mkOption {
      type = types.port;
      default = 9091;
      description = "Port for Authelia to listen on";
    };

    # Storage configuration
    storage = {
      type = mkOption {
        type = types.enum [ "sqlite" "postgres" "mysql" ];
        default = "sqlite";
        description = "Storage backend type (sqlite recommended for homelab)";
      };

      sqlitePath = mkOption {
        type = types.path;
        default = "${dataDir}/db.sqlite3";
        description = "Path to SQLite database file";
      };
    };

    # Session configuration
    session = {
      useRedis = mkOption {
        type = types.bool;
        default = false;
        description = "Use Redis for session storage (false = memory-based for homelab)";
      };

      expiration = mkOption {
        type = types.str;
        default = "1h";
        description = "Session expiration time";
      };

      inactivity = mkOption {
        type = types.str;
        default = "5m";
        description = "Session inactivity timeout";
      };
    };

    # Access control configuration
    accessControl = {
      defaultPolicy = mkOption {
        type = types.enum [ "bypass" "one_factor" "two_factor" "deny" ];
        default = "deny";
        description = "Default access policy for unmatched requests";
      };

      rules = mkOption {
        type = types.listOf (types.submodule {
          options = {
            domain = mkOption {
              type = types.either types.str (types.listOf types.str);
              description = "Domain(s) this rule applies to";
            };
            policy = mkOption {
              type = types.enum [ "bypass" "one_factor" "two_factor" "deny" ];
              description = "Access policy for this rule";
            };
            subject = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Subjects (users/groups) this rule applies to";
              example = [ "group:admins" "user:ryan" ];
            };
            resources = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Resource patterns (paths) this rule applies to";
              example = [ "^/api.*$" ];
            };
          };
        });
        default = [];
        description = "Access control rules for protected services";
        example = [
          {
            domain = "prometheus.holthome.net";
            policy = "two_factor";
            subject = [ "group:admins" ];
          }
        ];
      };

      # INTERNAL: Automatically aggregated from service reverseProxy.authelia configurations
      # Service modules should NOT write to this directly - it's populated automatically
      # by the service auto-registration logic based on reverseProxy.authelia settings
      declarativelyProtectedServices = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            domain = mkOption {
              type = types.str;
              description = "Fully qualified domain name of the protected service";
            };
            policy = mkOption {
              type = types.enum [ "bypass" "one_factor" "two_factor" ];
              description = "Authentication policy for this service";
            };
            subject = mkOption {
              type = types.listOf types.str;
              description = "List of subjects (groups/users) allowed to access";
            };
            bypassResources = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Regex patterns for paths that bypass authentication";
            };
          };
        });
        default = {};
        internal = true;
        description = ''
          INTERNAL: Aggregated access control rules from service reverse proxy configurations.
          Do not set this option directly - it is automatically populated from
          service reverseProxy.authelia configurations.
        '';
      };
    };

    # OIDC provider configuration
    oidc = {
      enable = mkEnableOption "OIDC identity provider";

      issuerUrl = mkOption {
        type = types.str;
        default = "https://auth.${cfg.domain}";
        description = "OIDC issuer URL";
      };

      clients = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              description = "Human-readable client description";
            };
            secret = mkOption {
              type = types.str;
              description = ''
                Argon2id hashed client secret.
                Generate the hash with: authelia crypto hash generate argon2 --password "your-secret"
                This should be the hash output (starting with $argon2id$...), not the plaintext secret.

                Storing the hash in configuration is safe - Authelia's security model relies on
                cryptographic hashing, and the hash cannot be reversed to obtain the original secret.
                This is the only supported method for OIDC client secrets per Authelia documentation.
              '';
            };
            redirectUris = mkOption {
              type = types.listOf types.str;
              description = "Allowed redirect URIs for this client";
            };
            scopes = mkOption {
              type = types.listOf types.str;
              default = [ "openid" "profile" "email" "groups" ];
              description = "OAuth2 scopes this client can request";
            };
          };
        });
        default = {};
        description = ''
          OIDC client configurations (attribute set keyed by client ID).
          Client secrets are loaded via environment variables at runtime.
        '';
      };
    };

    # Notifier configuration (required by Authelia)
    notifier = {
      type = mkOption {
        type = types.enum [ "filesystem" "smtp" ];
        default = "filesystem";
        description = "Notifier type (filesystem or smtp)";
      };

      filesystemPath = mkOption {
        type = types.str;
        default = "${dataDir}/notifications.txt";
        description = "Path for filesystem notifier (when type = filesystem)";
      };

      smtp = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "SMTP server host";
            };
            port = mkOption {
              type = types.port;
              default = 587;
              description = "SMTP server port";
            };
            username = mkOption {
              type = types.str;
              description = "SMTP username";
            };
            passwordFile = mkOption {
              type = types.path;
              description = "Path to file containing SMTP password";
            };
            sender = mkOption {
              type = types.str;
              description = "Sender email address";
            };
            subject = mkOption {
              type = types.str;
              default = "[Authelia] {title}";
              description = "Email subject template";
            };
          };
        });
        default = null;
        description = "SMTP configuration (when type = smtp)";
      };
    };

    # Secret files (SOPS-managed)
    secrets = {
      jwtSecretFile = mkOption {
        type = types.path;
        description = "Path to JWT secret file";
      };

      sessionSecretFile = mkOption {
        type = types.path;
        description = "Path to session encryption secret file";
      };

      storageEncryptionKeyFile = mkOption {
        type = types.path;
        description = "Path to storage encryption key file";
      };

      oidcHmacSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to OIDC HMAC secret file (required if OIDC enabled)";
      };

      oidcIssuerPrivateKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to OIDC issuer private key file (required if OIDC enabled)";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Authelia web interface";
    };

    # Standardized metrics collection
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 9091;
        path = "/metrics";
        labels = {
          service_type = "authentication";
          exporter = "authelia";
        };
      };
      description = "Prometheus metrics collection for Authelia";
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnitFile;
        labels = {
          service = "authelia";
          service_type = "authentication";
        };
      };
      description = "Log shipping configuration";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        frequency = mkDefault "daily";
        tags = mkDefault [ "authentication" "authelia" "sso" "database" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        paths = mkDefault [
          dataDir
        ];
      };
      description = "Backup configuration";
    };

    # Standardized notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = { onFailure = [ "system-alerts" ]; };
        customMessages = {
          failure = "Authelia SSO service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration";
    };

    # Preseed/DR configuration
    preseed = {
      enable = mkEnableOption "automatic data restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Order of restore methods to attempt";
      };
    };
  };

  config = mkMerge [
    # Main configuration
    (mkIf cfg.enable {
      # Assertions for required secrets and domain conflicts
      assertions = [
        {
          assertion = cfg.secrets.jwtSecretFile != null;
          message = "Authelia requires jwtSecretFile to be set";
        }
        {
          assertion = cfg.secrets.sessionSecretFile != null;
          message = "Authelia requires sessionSecretFile to be set";
        }
        {
          assertion = cfg.secrets.storageEncryptionKeyFile != null;
          message = "Authelia requires storageEncryptionKeyFile to be set";
        }
        # Detect domain conflicts - multiple services cannot use the same domain
        {
          assertion =
            let
              domains = lib.mapAttrsToList (name: svc: svc.domain) cfg.accessControl.declarativelyProtectedServices;
              uniqueDomains = lib.unique domains;
            in
            lib.length domains == lib.length uniqueDomains;
          message = ''
            Multiple services are configured with the same domain in Authelia access control!
            Each service must have a unique hostName. Check your reverseProxy.hostName settings.
            Conflicting domains: ${lib.concatStringsSep ", " (
              lib.filter (d: lib.count (x: x == d) (lib.mapAttrsToList (name: svc: svc.domain) cfg.accessControl.declarativelyProtectedServices) > 1)
              (lib.unique (lib.mapAttrsToList (name: svc: svc.domain) cfg.accessControl.declarativelyProtectedServices))
            )}
          '';
        }
        {
          assertion = cfg.oidc.enable -> cfg.secrets.oidcHmacSecretFile != null;
          message = "OIDC enabled but oidcHmacSecretFile not set";
        }
        {
          assertion = cfg.oidc.enable -> cfg.secrets.oidcIssuerPrivateKeyFile != null;
          message = "OIDC enabled but oidcIssuerPrivateKeyFile not set";
        }
      ];

      # Enable native Authelia service
      services.authelia.instances.${instanceName} = let
        # Convert OIDC clients from attribute set to list for Authelia YAML config
        # The attribute name becomes the client ID
        oidcClientsList = lib.mapAttrsToList (id: client: {
          inherit id;
          inherit (client) description redirectUris scopes secret;
        }) cfg.oidc.clients;
      in {
        enable = true;

        # Secrets configuration for native service
        secrets = {
          jwtSecretFile = cfg.secrets.jwtSecretFile;
          storageEncryptionKeyFile = cfg.secrets.storageEncryptionKeyFile;
        };

        # Secrets management via environment variables
        environmentVariables = {
          AUTHELIA_SESSION_SECRET_FILE = cfg.secrets.sessionSecretFile;
        } // lib.optionalAttrs cfg.oidc.enable {
          AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE = cfg.secrets.oidcHmacSecretFile;
          AUTHELIA_IDENTITY_PROVIDERS_OIDC_ISSUER_PRIVATE_KEY_FILE = cfg.secrets.oidcIssuerPrivateKeyFile;
        } // lib.optionalAttrs (cfg.notifier.type == "smtp" && cfg.notifier.smtp.passwordFile != null) {
          AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE = cfg.notifier.smtp.passwordFile;
        };

        settings = {
          theme = "dark";

          server = {
            address = "tcp://0.0.0.0:${toString cfg.port}";
            asset_path = "";
          };

          log = {
            level = "info";
            format = "text";
          };

          telemetry = {
            metrics = {
              enabled = cfg.metrics != null && cfg.metrics.enable;
              # Metrics are served on the same port as the web server, just on /metrics path
              # Don't specify address to use the default (same as server)
            };
          };

          totp = {
            disable = false;
            issuer = cfg.domain;
            period = 30;
            skew = 1;
          };

          webauthn = {
            disable = false;
            enable_passkey_login = true;  # Enable passwordless login with Passkeys (v4.39.0+)
            display_name = "Authelia";
            attestation_conveyance_preference = "indirect";
            # Enforce biometric/PIN for passwordless security
            selection_criteria = {
              user_verification = "required";
              discoverability = "preferred";  # Prefer discoverable credentials for passwordless
            };
            timeout = "60s";
          };

          # Authentication backend
          authentication_backend = {
            password_reset.disable = false;
            refresh_interval = "5m";

            file = {
              path = "${dataDir}/users.yaml";
              password = {
                algorithm = "argon2";
                argon2 = {
                  variant = "argon2id";
                  iterations = 3;
                  memory = 65536;
                  parallelism = 4;
                  key_length = 32;
                  salt_length = 16;
                };
              };
            };
          };

          # Session configuration
          session = {
            name = "authelia_session";
            domain = cfg.domain;
            same_site = "lax";
            expiration = cfg.session.expiration;
            inactivity = cfg.session.inactivity;
            remember_me = "1M";
          } // (if cfg.session.useRedis then {
            redis = {
              host = "localhost";
              port = 6379;
            };
          } else {});

          # Storage backend
          storage = mkIf (cfg.storage.type == "sqlite") {
            local = {
              path = cfg.storage.sqlitePath;
            };
          };

          # Access control
          access_control = {
            default_policy = cfg.accessControl.defaultPolicy;
            # Merge user-defined rules with auto-generated rules from service configurations
            rules =
              # First: User-defined explicit rules
              (map (rule: {
                domain = if builtins.isList rule.domain then rule.domain else [ rule.domain ];
                policy = rule.policy;
                subject = rule.subject;
                resources = rule.resources;
              }) cfg.accessControl.rules)
              ++
              # Second: Auto-generated rules from services with reverseProxy.authelia enabled
              # This creates two rules per service: one for bypass paths, one for main policy
              (lib.flatten (lib.mapAttrsToList (serviceName: svc:
                # Generate bypass rule first (higher priority in Authelia)
                (lib.optionals (svc.bypassResources != []) [{
                  domain = [ svc.domain ];
                  policy = "bypass";
                  resources = svc.bypassResources;
                }])
                ++
                # Then the main policy rule for everything else
                [{
                  domain = [ svc.domain ];
                  policy = svc.policy;
                  subject = svc.subject;
                }]
              ) cfg.accessControl.declarativelyProtectedServices));
          };

          # Notifier configuration (required)
          notifier = if cfg.notifier.type == "filesystem" then {
            disable_startup_check = false;
            filesystem = {
              filename = cfg.notifier.filesystemPath;
            };
          } else mkIf (cfg.notifier.smtp != null) {
            disable_startup_check = false;
            smtp = {
              address = "submission://${cfg.notifier.smtp.host}:${toString cfg.notifier.smtp.port}";
              username = cfg.notifier.smtp.username;
              password = ""; # Loaded from environment variable
              sender = cfg.notifier.smtp.sender;
              subject = cfg.notifier.smtp.subject;
              startup_check_address = "test@authelia.com";
              disable_require_tls = false;
              disable_html_emails = false;
            };
          };

          # OIDC configuration
          identity_providers = mkIf cfg.oidc.enable {
            oidc = {
              enable_client_debug_messages = false;
              minimum_parameter_entropy = 8;

              cors = {
                endpoints = [ "authorization" "token" "revocation" "introspection" "userinfo" ];
                allowed_origins_from_client_redirect_uris = true;
              };

              # Clients config with secret loaded from environment variables
              # Each client's secret is loaded via $env:CLIENT_ID_SECRET syntax
              clients = map (client: {
                inherit (client) id description scopes secret;
                authorization_policy = "two_factor";
                redirect_uris = client.redirectUris;
                grant_types = [ "refresh_token" "authorization_code" ];
                response_types = [ "code" ];
                response_modes = [ "form_post" "query" "fragment" ];
                token_endpoint_auth_method = "client_secret_basic";
              }) oidcClientsList;
            };
          };
        };
      };

      # Override systemd service for notifications and preseed
      systemd.services."authelia-${instanceName}" = mkMerge [
        # Add failure notifications
        (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@authelia-failure:%n.service" ];
        })

        # Add preseed dependency
        (mkIf cfg.preseed.enable {
          wants = [ "preseed-authelia.service" ];
          after = [ "preseed-authelia.service" ];
        })
      ];

      # Auto-register with Caddy reverse proxy if configured
      modules.services.caddy.virtualHosts.authelia = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName or "auth.${cfg.domain}";

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };

        # No auth on the auth service itself!
        auth = null;

        security = cfg.reverseProxy.security // {
          customHeaders = (cfg.reverseProxy.security.customHeaders or {}) // {
            "X-Frame-Options" = "SAMEORIGIN";
            "X-Content-Type-Options" = "nosniff";
          };
        };

        extraConfig = cfg.reverseProxy.extraConfig or "";
      };

      # ZFS dataset management
      modules.storage.datasets.services."authelia-${instanceName}" = {
        mountpoint = "/var/lib/authelia-${instanceName}";
        recordsize = "16K";  # Optimal for SQLite
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "authelia-${instanceName}";
        group = "authelia-${instanceName}";
        mode = "0750";
      };
    })

    # Preseed service for disaster recovery
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "authelia-${instanceName}";
        dataset = datasetPath;
        mountpoint = "/var/lib/authelia-${instanceName}";
        mainServiceUnit = serviceUnitFile;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ "/var/lib/authelia-${instanceName}" ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "authelia-${instanceName}";
        group = "authelia-${instanceName}";
      }
    ))
  ];
}
