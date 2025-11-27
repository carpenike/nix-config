{ lib, pkgs, config, ... }:
let
  inherit (lib)
    mkIf
    mkMerge
    mkEnableOption
    mkOption
    mkDefault
    types;

  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  format = pkgs.formats.keyValue { };

  cfg = config.modules.services.pocketid;
  serviceName = "pocket-id";
  serviceUnit = "${serviceName}.service";
  dataDirDefault = "/var/lib/${serviceName}";
  defaultDomain = config.networking.domain or "holthome.net";
  defaultPublicUrl = "https://auth.${defaultDomain}";

  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/pocketid";

  sqlitePath = if cfg.database.sqlite.path != null then cfg.database.sqlite.path else "${cfg.dataDir}/db.sqlite3";

  computedDbConnectionString =
    if cfg.database.customConnectionString != null then cfg.database.customConnectionString
    else if cfg.database.backend == "sqlite" then "file:${sqlitePath}"
    else cfg.database.postgresql.connectionString;

  metricsEnabled = cfg.metrics != null && cfg.metrics.enable;
  listenPort = toString cfg.listen.port;

  boolToString = value: if value then "true" else "false";

  smtpEnvSettings =
    if cfg.smtp.enable then
      {
        SMTP_HOST = cfg.smtp.host;
        SMTP_PORT = toString cfg.smtp.port;
        SMTP_FROM = cfg.smtp.fromAddress;
        SMTP_TLS = cfg.smtp.tlsMode;
        SMTP_SKIP_CERT_VERIFY = boolToString cfg.smtp.skipCertVerify;
      }
      // lib.optionalAttrs (cfg.smtp.username != null) { SMTP_USER = cfg.smtp.username; }
      // lib.optionalAttrs (cfg.smtp.passwordFile != null) { SMTP_PASSWORD_FILE = cfg.smtp.passwordFile; }
      // {
        EMAIL_LOGIN_NOTIFICATION_ENABLED = boolToString cfg.smtp.sendLoginNotifications;
        EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED = boolToString cfg.smtp.sendAdminOneTimeCodes;
        EMAIL_API_KEY_EXPIRATION_ENABLED = boolToString cfg.smtp.sendApiKeyExpiry;
        EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED = boolToString cfg.smtp.allowUnauthenticatedOneTimeCodes;
      }
    else
      { };

  baseSettings = {
    APP_URL = cfg.publicUrl;
    INTERNAL_APP_URL = cfg.internalAppUrl or cfg.publicUrl;
    TRUST_PROXY = cfg.trustProxy;
    PORT = listenPort;
    HOST = cfg.listen.address;
    DB_CONNECTION_STRING = computedDbConnectionString;
  } // lib.optionalAttrs metricsEnabled {
    OTEL_METRICS_EXPORTER = "prometheus";
    OTEL_EXPORTER_PROMETHEUS_HOST = cfg.metrics.interface;
    OTEL_EXPORTER_PROMETHEUS_PORT = toString cfg.metrics.port;
  };

  settingsWithSmtp = lib.recursiveUpdate baseSettings smtpEnvSettings;
  finalEnvSettings = lib.recursiveUpdate settingsWithSmtp cfg.extraSettings;
  generatedEnvFile = format.generate "${serviceName}-env-vars" finalEnvSettings;
  environmentFiles =
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ [ generatedEnvFile ];

  reverseProxyEnabled = cfg.reverseProxy != null && cfg.reverseProxy.enable;

  defaultBackend = {
    scheme = "http";
    host = cfg.listen.address;
    port = cfg.listen.port;
  };

  hasNotifications = config.modules.notifications.enable or false;
in
{
  options.modules.services.pocketid = {
    enable = mkEnableOption "Pocket ID passkey identity provider";

    package = mkOption {
      type = types.package;
      default = pkgs.pocket-id;
      description = "Pocket ID package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "pocket-id";
      description = "System user that runs Pocket ID.";
    };

    group = mkOption {
      type = types.str;
      default = "pocket-id";
      description = "System group that runs Pocket ID.";
    };

    dataDir = mkOption {
      type = types.path;
      default = dataDirDefault;
      description = "Persistent data directory for Pocket ID.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional environment file (SOPS managed) loaded before starting Pocket ID.";
    };

    publicUrl = mkOption {
      type = types.str;
      default = defaultPublicUrl;
      description = "Public URL used by clients when redirecting back to Pocket ID.";
    };

    trustProxy = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to set TRUST_PROXY=true (required when running behind Caddy).";
    };

    internalAppUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Override the INTERNAL_APP_URL used in OIDC metadata (defaults to publicUrl when null).";
    };

    listen = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Interface Pocket ID binds to.";
      };

      port = mkOption {
        type = types.port;
        default = 1411;
        description = "Port Pocket ID listens on (reverse proxy terminates TLS).";
      };
    };

    database = {
      backend = mkOption {
        type = types.enum [ "sqlite" "postgresql" ];
        default = "sqlite";
        description = "Database engine for Pocket ID.";
      };

      sqlite = {
        path = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Override SQLite database path. Defaults to <dataDir>/db.sqlite3 when null.";
        };
      };

      postgresql = {
        connectionString = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "PostgreSQL connection string (postgresql://user:pw@host:port/db). Required when backend=postgresql.";
        };
      };

      customConnectionString = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Fully override DB_CONNECTION_STRING for advanced deployments.";
      };
    };

    smtp = {
      enable = mkEnableOption "SMTP email delivery for Pocket ID notifications";

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "SMTP server hostname.";
      };

      port = mkOption {
        type = types.port;
        default = 587;
        description = "SMTP server port.";
      };

      fromAddress = mkOption {
        type = types.str;
        default = "pocketid@${defaultDomain}";
        description = "Sender email address used in outgoing messages.";
      };

      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "SMTP username for authenticated relays.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing the SMTP password (e.g., SOPS secret).";
      };

      tlsMode = mkOption {
        type = types.enum [ "none" "starttls" "tls" ];
        default = "starttls";
        description = "TLS mode to use when talking to the SMTP relay.";
      };

      skipCertVerify = mkOption {
        type = types.bool;
        default = false;
        description = "Skip certificate verification for SMTP connections (for self-signed certs).";
      };

      sendLoginNotifications = mkOption {
        type = types.bool;
        default = false;
        description = "Send an email when a user logs in from a new device.";
      };

      sendAdminOneTimeCodes = mkOption {
        type = types.bool;
        default = false;
        description = "Allow administrators to send one-time codes via email.";
      };

      sendApiKeyExpiry = mkOption {
        type = types.bool;
        default = false;
        description = "Notify users before their API keys expire.";
      };

      allowUnauthenticatedOneTimeCodes = mkOption {
        type = types.bool;
        default = false;
        description = "Allow non-authenticated users to request email one-time codes (less secure).";
      };
    };

    extraSettings = mkOption {
      type = types.attrsOf (types.oneOf [ types.bool types.int types.float types.str ]);
      default = { };
      description = "Additional environment variables passed to Pocket ID.";
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for exposing Pocket ID via Caddy.";
    };

    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = false;
        port = 9464;
        path = "/metrics";
        interface = "127.0.0.1";
        labels = {
          service = "pocket-id";
          service_type = "identity";
          exporter = "otel";
        };
      };
      description = "Prometheus metrics exporter toggle (uses OTEL_EXPORTER_PROMETHEUS_* settings).";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnit;
        labels = {
          service = serviceName;
          service_type = "identity";
        };
      };
      description = "Log shipping configuration for Pocket ID.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        frequency = mkDefault "daily";
        tags = mkDefault [ "identity" "pocketid" "sqlite" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        paths = mkDefault [ cfg.dataDir ];
      };
      description = "Backup configuration for Pocket ID data.";
    };

    preseed = {
      enable = mkEnableOption "automatic data restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = computedDbConnectionString != null;
          message = "Pocket ID requires a DB connection string (set database.postgresql.connectionString or customConnectionString).";
        }
        {
          assertion = !reverseProxyEnabled || cfg.reverseProxy.caddySecurity == null || !(cfg.reverseProxy.caddySecurity.enable or false);
          message = "Do not protect the Pocket ID portal with caddy-security—it's the identity provider.";
        }
        {
          assertion = !cfg.smtp.enable || (cfg.smtp.host != "" && cfg.smtp.fromAddress != "");
          message = "Pocket ID SMTP host and fromAddress must be set when SMTP is enabled.";
        }
      ] ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.repositoryUrl != "";
        message = "Pocket ID preseed.enable requires preseed.repositoryUrl to be set.";
      }) ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.passwordFile != null;
        message = "Pocket ID preseed.enable requires preseed.passwordFile to be set.";
      });

      # Reverse proxy registration (Caddy)
      modules.services.caddy.virtualHosts.pocketid = mkIf reverseProxyEnabled {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = cfg.reverseProxy.backend or defaultBackend;
        auth = cfg.reverseProxy.auth;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
        authelia = null;
        caddySecurity = null;
      };

      # Register dataset for declarative ZFS management
      modules.storage.datasets.services.pocketid = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # System user/group declarations
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = lib.mkForce "/var/empty";
      };

      users.groups.${cfg.group} = { };

      # Tighten service sandboxing + ensure ZFS mount is ready
      systemd.services.${serviceName} = {
        description = "Pocket ID";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ lib.optionals cfg.preseed.enable [ "preseed-pocketid.service" ];
        wants = [ "network.target" ] ++ lib.optionals cfg.preseed.enable [ "preseed-pocketid.service" ];
        unitConfig = {
          RequiresMountsFor = [ cfg.dataDir ];
        };
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.mkForce "${cfg.package}/bin/pocket-id";
          Restart = "always";
          EnvironmentFile = environmentFiles;
          User = lib.mkForce cfg.user;
          Group = lib.mkForce cfg.group;
          WorkingDirectory = lib.mkForce cfg.dataDir;
          StateDirectory = lib.mkForce serviceName;
          StateDirectoryMode = lib.mkForce "0750";
          DynamicUser = lib.mkForce false;
          ReadWritePaths = lib.mkForce [ cfg.dataDir ];
          UMask = lib.mkForce "0027";
          PrivateTmp = true;
          ProtectSystem = lib.mkForce "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          SystemCallFilter = lib.mkForce "@system-service";
        };
      };

      # Observability metadata for metrics/logging discovery happens automatically via shared submodules
    }

    (mkIf (hasNotifications && cfg.logging != null && cfg.logging.enable) {
      modules.notifications.templates."${serviceName}-failure" = {
        enable = mkDefault true;
        title = mkDefault ''<b><font color="red">✗ Pocket ID failure</font></b>'';
        body = mkDefault ''Pocket ID on ${config.networking.hostName} failed. Check journalctl -u ${serviceUnit}'';
      };
    })

    # Add the preseed service itself
    (mkIf cfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "pocketid";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnit;
        replicationCfg = null; # Replication config handled at host level
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
        hasCentralizedNotifications = hasNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ]);
}
