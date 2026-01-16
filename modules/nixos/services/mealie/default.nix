{ lib, mylib, pkgs, config, podmanLib, ... }:
with lib;
let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.mealie or { };
  notificationsCfg = config.modules.notifications or { };
  hasCentralizedNotifications = notificationsCfg.enable or false;

  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };
  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/mealie"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  serviceName = "mealie";
  backend = config.virtualisation.oci-containers.backend;
  serviceAttrName = "${backend}-${serviceName}";
  mainServiceUnit = "${serviceAttrName}.service";

  envDir = "/run/${serviceName}";
  envFile = "${envDir}/env";

  boolStr = value: if value then "true" else "false";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  effectiveBaseUrl =
    if cfg.baseUrl != null then cfg.baseUrl
    else if cfg.reverseProxy != null && cfg.reverseProxy.enable then
      "https://${cfg.reverseProxy.hostName}"
    else
      "http://${cfg.listenAddress}:${toString cfg.listenPort}";

  databaseEnv =
    if cfg.database.engine == "postgres" then {
      DB_ENGINE = "postgres";
      POSTGRES_USER = cfg.database.user;
      POSTGRES_DB = cfg.database.name;
      POSTGRES_SERVER = cfg.database.host;
      POSTGRES_PORT = toString cfg.database.port;
    } else {
      DB_ENGINE = "sqlite";
    };

  smtpEnv =
    if cfg.smtp.enable then {
      SMTP_HOST = cfg.smtp.host;
      SMTP_PORT = toString cfg.smtp.port;
      SMTP_FROM_NAME = cfg.smtp.fromName;
      SMTP_FROM_EMAIL = cfg.smtp.fromEmail;
      SMTP_AUTH_STRATEGY = cfg.smtp.strategy;
      SMTP_USER = cfg.smtp.username;
    } else { };

  oidcEnv =
    if cfg.oidc.enable then
      {
        OIDC_AUTH_ENABLED = "true";
        OIDC_CONFIGURATION_URL = cfg.oidc.configurationUrl;
        OIDC_CLIENT_ID = cfg.oidc.clientId;
        OIDC_PROVIDER_NAME = cfg.oidc.providerName;
        OIDC_SIGNUP_ENABLED = boolStr cfg.oidc.signupEnabled;
        OIDC_AUTO_REDIRECT = boolStr cfg.oidc.autoRedirect;
        OIDC_REMEMBER_ME = boolStr cfg.oidc.rememberMe;
        OIDC_USER_CLAIM = cfg.oidc.userClaim;
        OIDC_NAME_CLAIM = cfg.oidc.nameClaim;
        OIDC_GROUPS_CLAIM = cfg.oidc.groupsClaim;
      }
      // (lib.optionalAttrs (cfg.oidc.userGroup != null) { OIDC_USER_GROUP = cfg.oidc.userGroup; })
      // (lib.optionalAttrs (cfg.oidc.adminGroup != null) { OIDC_ADMIN_GROUP = cfg.oidc.adminGroup; })
      // (lib.optionalAttrs (cfg.oidc.scopes != [ ]) { OIDC_SCOPES_OVERRIDE = lib.concatStringsSep " " cfg.oidc.scopes; })
    else
      { OIDC_AUTH_ENABLED = "false"; };

  openaiEnv =
    if cfg.openai.enable then
      {
        OPENAI_MODEL = cfg.openai.model;
        OPENAI_WORKERS = toString cfg.openai.workers;
        OPENAI_SEND_DATABASE_DATA = boolStr cfg.openai.sendDatabaseData;
        OPENAI_ENABLE_IMAGE_SERVICES = boolStr cfg.openai.enableImageServices;
        OPENAI_REQUEST_TIMEOUT = toString cfg.openai.requestTimeout;
      }
      // (lib.optionalAttrs (cfg.openai.baseUrl != null) { OPENAI_BASE_URL = cfg.openai.baseUrl; })
      // (lib.optionalAttrs (cfg.openai.customHeaders != null) { OPENAI_CUSTOM_HEADERS = cfg.openai.customHeaders; })
      // (lib.optionalAttrs (cfg.openai.customParams != null) { OPENAI_CUSTOM_PARAMS = cfg.openai.customParams; })
    else
      { };

  credentials =
    (lib.optional (cfg.database.engine == "postgres") "db_password:${cfg.database.passwordFile}")
    ++ (lib.optional (cfg.smtp.enable && cfg.smtp.passwordFile != null) "smtp_password:${cfg.smtp.passwordFile}")
    ++ (lib.optional (cfg.oidc.enable && cfg.oidc.clientSecretFile != null) "oidc_client_secret:${cfg.oidc.clientSecretFile}")
    ++ (lib.optional (cfg.openai.enable && cfg.openai.apiKeyFile != null) "openai_api_key:${cfg.openai.apiKeyFile}");
in
{
  options.modules.services.mealie = {
    enable = mkEnableOption "Mealie self-hosted recipe manager";

    image = mkOption {
      type = types.str;
      default = "ghcr.io/mealie-recipes/mealie:v3.5.0";
      description = ''
        Container image reference for Mealie. Pin to a specific version tag or digest
        to guarantee repeatable deployments.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/mealie";
      description = "Directory where Mealie stores persistent state.";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "Backing ZFS dataset for Mealie data; defaults to parentDataset/mealie.";
    };

    user = mkOption {
      type = types.str;
      default = "mealie";
      description = "System user that owns Mealie data.";
    };

    group = mkOption {
      type = types.str;
      default = "mealie";
      description = "System group that owns Mealie data.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Interface that exposes the container port (Caddy proxies requests).";
    };

    listenPort = mkOption {
      type = types.port;
      default = 9925;
      description = "Host port that forwards to the container's port 9000.";
    };

    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Value for the BASE_URL environment variable. When unset Mealie derives the URL
        from the configured reverse proxy host (https://<host>). If no reverse proxy is configured,
        fall back to http://<listenAddress>:<listenPort>.
      '';
    };

    timezone = mkOption {
      type = types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone passed to the container.";
    };

    allowSignup = mkOption {
      type = types.bool;
      default = false;
      description = "Controls ALLOW_SIGNUP environment variable (public registrations).";
    };

    maxWorkers = mkOption {
      type = types.int;
      default = 1;
      description = "Value for MAX_WORKERS to keep Python memory usage in check.";
    };

    webConcurrency = mkOption {
      type = types.int;
      default = 1;
      description = "WEB_CONCURRENCY passed to Gunicorn.";
    };

    defaults = mkOption {
      type = types.submodule {
        options = {
          email = mkOption {
            type = types.str;
            default = "changeme@example.com";
            description = "DEFAULT_EMAIL for the bootstrap admin account.";
          };
          group = mkOption {
            type = types.str;
            default = "Home";
            description = "DEFAULT_GROUP used for first-run data.";
          };
          household = mkOption {
            type = types.str;
            default = "Family";
            description = "DEFAULT_HOUSEHOLD name.";
          };
        };
      };
      default = { };
      description = "Initial admin metadata passed via environment variables.";
    };

    podmanNetwork = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional Podman network to attach to.";
    };

    extraHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra /etc/hosts entries for the container.

        Useful for overriding DNS resolution when containers need to reach
        host services via internal bridge IPs (hairpin NAT workaround).

        Example: When using PocketID SSO, the container needs to reach
        id.holthome.net but public DNS points to Cloudflare. Use this to
        point to the Podman bridge IP where Caddy listens internally.
      '';
      example = {
        "id.holthome.net" = "10.89.0.1";
      };
    };

    resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1024M";
        memoryReservation = "512M";
        cpus = "1.0";
      };
      description = "Container resource limits (translated to Podman run options).";
    };

    healthcheck = mkOption {
      type = types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "120s";
      };
      description = "Container healthcheck configuration.";
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy definition for automatic Caddy + Authelia wiring.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "recipes";
        };
      };
      description = "Log shipping metadata consumed by the observability stack.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Restic backup configuration for Mealie state.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "Mealie failed on ${config.networking.hostName}";
      };
      description = "Notification policy for service failures.";
    };

    preseed = {
      enable = mkEnableOption "automatic restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for cloud credentials.";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered list of restore strategies.";
      };
    };

    database = mkOption {
      type = types.submodule {
        options = {
          engine = mkOption {
            type = types.enum [ "sqlite" "postgres" ];
            default = "postgres";
            description = "Database backend used by Mealie.";
          };
          host = mkOption {
            type = types.str;
            default = "host.containers.internal";
            description = "Database host (for postgres deployments).";
          };
          port = mkOption {
            type = types.port;
            default = 5432;
            description = "Database port.";
          };
          name = mkOption {
            type = types.str;
            default = "mealie";
            description = "Database name.";
          };
          user = mkOption {
            type = types.str;
            default = "mealie";
            description = "Database role.";
          };
          passwordFile = mkOption {
            type = types.path;
            default = /var/empty;
            description = "SOPS-managed password for the postgres role.";
          };
          manageDatabase = mkOption {
            type = types.bool;
            default = true;
            description = "Automatically provision the database via the shared PostgreSQL module.";
          };
          localInstance = mkOption {
            type = types.bool;
            default = true;
            description = "Whether the database runs on the same host (adds dependencies).";
          };
          extensions = mkOption {
            type = types.listOf (types.submodule {
              options = {
                name = mkOption { type = types.str; description = "Extension name"; };
                schema = mkOption { type = types.nullOr types.str; default = null; description = "Schema to install into"; };
                version = mkOption { type = types.nullOr types.str; default = null; description = "Specific version"; };
                dropBeforeCreate = mkOption { type = types.bool; default = false; description = "Drop extension before creating"; };
                dropCascade = mkOption { type = types.bool; default = true; description = "Use CASCADE when dropping"; };
                updateToLatest = mkOption { type = types.bool; default = true; description = "Run ALTER EXTENSION ... UPDATE"; };
              };
            });
            default = [{ name = "pg_trgm"; }];
            description = "Extensions enabled for the Mealie database.";
          };
          schemaMigrations = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            description = "Optional schema migrations seeding definition to hand off to PostgreSQL module.";
          };
        };
      };
      default = { };
      description = "Database configuration.";
    };

    smtp = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "SMTP email support";
          host = mkOption {
            type = types.str;
            default = "smtp.gmail.com";
            description = "SMTP host.";
          };
          port = mkOption {
            type = types.port;
            default = 587;
            description = "SMTP port.";
          };
          username = mkOption {
            type = types.str;
            default = "";
            description = "SMTP username.";
          };
          passwordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Secret containing SMTP password.";
          };
          fromName = mkOption {
            type = types.str;
            default = "Mealie";
            description = "Display name for outbound mail.";
          };
          fromEmail = mkOption {
            type = types.str;
            default = "mealie@example.com";
            description = "From address for outbound mail.";
          };
          strategy = mkOption {
            type = types.enum [ "TLS" "SSL" "NONE" ];
            default = "TLS";
            description = "SMTP authentication strategy.";
          };
        };
      };
      default = { };
      description = "SMTP configuration passed to Mealie.";
    };

    oidc = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "OpenID Connect authentication";
          configurationUrl = mkOption {
            type = types.str;
            default = "https://auth.example.com/.well-known/openid-configuration";
            description = "Provider discovery URL.";
          };
          clientId = mkOption {
            type = types.str;
            default = "mealie";
            description = "OIDC client ID.";
          };
          clientSecretFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Secret containing OIDC client secret.";
          };
          providerName = mkOption {
            type = types.str;
            default = "SSO";
            description = "Label rendered on the login button.";
          };
          userClaim = mkOption {
            type = types.str;
            default = "email";
            description = "Claim used to match users.";
          };
          nameClaim = mkOption {
            type = types.str;
            default = "name";
            description = "Display name claim.";
          };
          groupsClaim = mkOption {
            type = types.str;
            default = "groups";
            description = "Claim that carries group membership.";
          };
          userGroup = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional group required for access.";
          };
          adminGroup = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional group promoted to admin.";
          };
          scopes = mkOption {
            type = types.listOf types.str;
            default = [ "openid" "profile" "email" ];
            description = "OIDC scopes requested.";
          };
          signupEnabled = mkOption {
            type = types.bool;
            default = true;
            description = "Allow auto-provisioning when a user signs in for the first time.";
          };
          autoRedirect = mkOption {
            type = types.bool;
            default = false;
            description = "Skip local login form and redirect straight to the IdP.";
          };
          rememberMe = mkOption {
            type = types.bool;
            default = true;
            description = "Mirror the Remember Me checkbox automatically.";
          };
        };
      };
      default = { };
      description = "OIDC configuration surfaced to Mealie.";
    };

    openai = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "OpenAI-powered recipe tooling";
          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Secret containing the OpenAI API key.";
          };
          model = mkOption {
            type = types.str;
            default = "gpt-4o";
            description = "OpenAI model identifier (e.g. gpt-4o, gpt-4o-mini).";
          };
          baseUrl = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional OpenAI-compatible base URL (set when using custom gateways).";
          };
          customHeaders = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "JSON-encoded custom headers passed to OpenAI requests.";
          };
          customParams = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "JSON-encoded custom query parameters for OpenAI requests.";
          };
          workers = mkOption {
            type = types.int;
            default = 2;
            description = "Concurrent OpenAI workers per request.";
          };
          sendDatabaseData = mkOption {
            type = types.bool;
            default = true;
            description = "Send existing ingredient metadata to OpenAI to improve parsing accuracy.";
          };
          enableImageServices = mkOption {
            type = types.bool;
            default = true;
            description = "Enable OpenAI-powered image imports.";
          };
          requestTimeout = mkOption {
            type = types.int;
            default = 300;
            description = "Timeout (seconds) for OpenAI API calls.";
          };
        };
      };
      default = { enable = false; };
      description = "OpenAI integration settings for Mealie.";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.database.engine != "postgres" || cfg.database.passwordFile != null;
          message = "modules.services.mealie.database.passwordFile must be set when using PostgreSQL.";
        }
        {
          assertion = !(cfg.smtp.enable && cfg.smtp.passwordFile == null);
          message = "SMTP passwordFile must be provided when SMTP is enabled.";
        }
        {
          assertion = !(cfg.oidc.enable && cfg.oidc.clientSecretFile == null);
          message = "OIDC client secret must be provided when OIDC is enabled.";
        }
        {
          assertion = !(cfg.openai.enable && cfg.openai.apiKeyFile == null);
          message = "OpenAI API key must be provided when OpenAI integration is enabled.";
        }
      ];

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        description = "Mealie service account";
      };

      users.groups.${cfg.group} = { };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
        "d ${envDir} 0700 root root -"
      ];

      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      modules.services.postgresql.databases.${cfg.database.name} = mkIf (cfg.database.engine == "postgres" && cfg.database.manageDatabase) {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        extensions = cfg.database.extensions;
        permissionsPolicy = "owner-readwrite+readonly-select";
        schemaMigrations = cfg.database.schemaMigrations;
      };

      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        environmentFiles = [ envFile ];
        environment = {
          PUID = toString config.users.users.${cfg.user}.uid;
          PGID = toString config.users.groups.${cfg.group}.gid;
          TZ = cfg.timezone;
          BASE_URL = effectiveBaseUrl;
          ALLOW_SIGNUP = boolStr cfg.allowSignup;
          MAX_WORKERS = toString cfg.maxWorkers;
          WEB_CONCURRENCY = toString cfg.webConcurrency;
          DEFAULT_EMAIL = cfg.defaults.email;
          DEFAULT_GROUP = cfg.defaults.group;
          DEFAULT_HOUSEHOLD = cfg.defaults.household;
        }
        // databaseEnv
        // smtpEnv
        // oidcEnv
        // openaiEnv;
        volumes = [
          "${cfg.dataDir}:/app/data:rw"
        ];
        ports = [
          "${cfg.listenAddress}:${toString cfg.listenPort}:9000/tcp"
        ];
        resources = cfg.resources;
        extraOptions = [ "--pull=newer" ]
          ++ lib.optionals (cfg.podmanNetwork != null) [ "--network=${cfg.podmanNetwork}" ]
          ++ lib.optionals (cfg.extraHosts != { }) (
          lib.mapAttrsToList (host: ip: "--add-host=${host}:${ip}") cfg.extraHosts
        )
          ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9000/api/app/about', timeout=5)" || exit 1''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ];
      };

      systemd.services.${serviceAttrName} = mkMerge [
        {
          after = [ "network-online.target" ]
            ++ lib.optional (cfg.database.engine == "postgres" && cfg.database.localInstance) "postgresql.service"
            ++ lib.optionals cfg.preseed.enable [ "mealie-preseed.service" ];
          wants = [ "network-online.target" ]
            ++ lib.optionals cfg.preseed.enable [ "mealie-preseed.service" ];
          requires =
            lib.optional (cfg.database.engine == "postgres" && cfg.database.manageDatabase && cfg.database.localInstance)
              "postgresql-provision-databases.service";
          serviceConfig = {
            LoadCredential = credentials;
            Restart = lib.mkForce "on-failure";
            RestartSec = "10s";
          };
          preStart = ''
            set -euo pipefail
            install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
            install -d -m 700 ${envDir}
            tmp="${envFile}.tmp"
            trap 'rm -f "$tmp"' EXIT
            {
            ${lib.optionalString (cfg.database.engine == "postgres") ''
              printf "POSTGRES_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")"
            ''}
            ${lib.optionalString (cfg.smtp.enable && cfg.smtp.passwordFile != null) ''
              printf "SMTP_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/smtp_password")"
            ''}
            ${lib.optionalString (cfg.oidc.enable && cfg.oidc.clientSecretFile != null) ''
              printf "OIDC_CLIENT_SECRET=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/oidc_client_secret")"
            ''}
            ${lib.optionalString (cfg.openai.enable && cfg.openai.apiKeyFile != null) ''
              printf "OPENAI_API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/openai_api_key")"
            ''}
            } > "$tmp"
            install -m 600 "$tmp" ${envFile}
          '';
        }
        (mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@${serviceName}-failure:%n.service" ];
        })
      ];

      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) (
        let
          defaultBackend = {
            scheme = "http";
            host = cfg.listenAddress;
            port = cfg.listenPort;
          };
          configuredBackend = cfg.reverseProxy.backend or { };
        in
        {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = recursiveUpdate defaultBackend configuredBackend;
          auth = cfg.reverseProxy.auth;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        }
      );

      modules.backup.restic.jobs.${serviceName} = mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency;
        retention = cfg.backup.retention;
        paths = if cfg.backup.paths != [ ] then cfg.backup.paths else [ cfg.dataDir ];
        excludePatterns = cfg.backup.excludePatterns;
        tags = cfg.backup.tags;
        useSnapshots = cfg.backup.useSnapshots or true;
        zfsDataset = cfg.backup.zfsDataset or datasetPath;
      };

      modules.notifications.templates."${serviceName}-failure" = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        enable = true;
        priority = "high";
        title = "❌ Mealie service failed";
        body = ''
          <b>Host:</b> ${config.networking.hostName}
          <b>Service:</b> ${mainServiceUnit}

          Check logs: <code>journalctl -u ${mainServiceUnit} -n 200</code>
        '';
      };

      # NOTE: Service alerts are defined at host level (e.g., hosts/forge/services/mealie.nix)
      # to keep modules portable and not assume Prometheus availability
    })

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
