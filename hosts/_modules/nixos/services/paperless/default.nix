# hosts/_modules/nixos/services/paperless/default.nix
#
# Paperless-ngx document management system
#
# Architecture:
# - Wraps native services.paperless NixOS module with homelab integrations
# - Native OIDC authentication via PocketID (django-allauth)
# - PostgreSQL database via shared provisioning module
# - Tika + Gotenberg containers for Office/email document processing
# - NFS storage for documents (/mnt/data/paperless), ZFS for service state
#
# Key design decisions:
# - Native service preferred (following plex pattern)
# - OIDC via PAPERLESS_SOCIALACCOUNT_PROVIDERS (following mealie pattern)
# - Backup only covers ZFS service state, NOT NFS document storage (NAS handles that)
# - OCR languages configurable (default eng+deu per user request)

{ lib
, mylib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.services.paperless;

  # Import shared type definitions
  sharedTypes = mylib.types;

  # Import storage helpers for preseed service generation
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  # Define storage configuration for consistent access
  storageCfg = config.modules.storage;

  # Construct the dataset path for paperless service state
  datasetPath = "${storageCfg.datasets.parentDataset}/paperless";

  serviceName = "paperless";

  # Build OIDC provider JSON for django-allauth
  oidcProviderJson = builtins.toJSON {
    openid_connect = {
      OAUTH_PKCE_ENABLED = "True";
      APPS = [{
        provider_id = cfg.oidc.providerId;
        name = cfg.oidc.providerName;
        client_id = cfg.oidc.clientId;
        secret = "__OIDC_CLIENT_SECRET__"; # Placeholder, replaced at runtime
        settings = {
          server_url = cfg.oidc.serverUrl;
        } // lib.optionalAttrs (cfg.oidc.claims != null) {
          claims = cfg.oidc.claims;
        };
      }];
    };
  };

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    let
      sanoidDatasets = config.modules.backup.sanoid.datasets;
      replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
    in
    if replicationInfo != null then
      {
        sourcePath = dsPath;
        replication = replicationInfo;
      }
    else
      (
        let
          parts = lib.splitString "/" dsPath;
          parentPath = lib.concatStringsSep "/" (lib.init parts);
        in
        if parentPath == "" || parts == [ ] then
          null
        else
          findReplication parentPath
      );

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
  options.modules.services.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx document management system";

    # ==========================================================================
    # Storage Configuration
    # ==========================================================================

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/paperless";
      description = ''
        Directory for Paperless service state (database, index, thumbnails).
        This is stored on ZFS and backed up.
      '';
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/paperless/media";
      description = ''
        Directory for archived documents. On NFS, not backed up by this module
        (NAS handles its own snapshots).
      '';
    };

    consumptionDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/paperless/consume";
      description = "Directory to watch for incoming documents.";
    };

    exportDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/paperless/export";
      description = "Directory for document exports.";
    };

    # ==========================================================================
    # Service Configuration
    # ==========================================================================

    port = lib.mkOption {
      type = lib.types.port;
      default = 28981;
      description = "Port for the Paperless web interface.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to bind the web interface to.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "paperless";
      description = "System user for Paperless.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "paperless";
      description = "System group for Paperless.";
    };

    # ==========================================================================
    # OCR Configuration
    # ==========================================================================

    ocr = {
      languages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "eng" "deu" ];
        description = ''
          List of OCR languages to enable. Uses Tesseract language codes.
          Common: eng (English), deu (German), fra (French), spa (Spanish).
        '';
        example = [ "eng" "deu" "fra" ];
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "skip" "redo" "force" "skip_noarchive" ];
        default = "skip";
        description = ''
          OCR mode:
          - skip: Skip OCR if document already has text
          - redo: Re-OCR all documents
          - force: Force OCR even if text exists
          - skip_noarchive: Like skip, but don't store original
        '';
      };

      clean = lib.mkOption {
        type = lib.types.enum [ "clean" "clean-final" "none" ];
        default = "clean";
        description = "Image cleaning mode for OCR preprocessing.";
      };

      deskew = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable automatic deskewing of scanned documents.";
      };

      rotatePages = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable automatic page rotation.";
      };

      rotateThreshold = lib.mkOption {
        type = lib.types.float;
        default = 12.0;
        description = "Threshold for automatic page rotation (degrees).";
      };

      outputType = lib.mkOption {
        type = lib.types.enum [ "pdfa" "pdfa-1" "pdfa-2" "pdfa-3" "pdf" ];
        default = "pdfa";
        description = "Output PDF type after OCR processing.";
      };
    };

    # ==========================================================================
    # Document Processing
    # ==========================================================================

    tika = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable Apache Tika for Office document text extraction.
          Required for processing .docx, .xlsx, .pptx, .odt files.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9998;
        description = "Port for the Tika server.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/paperless-ngx/tika:latest";
        description = "Container image for Apache Tika.";
      };
    };

    gotenberg = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable Gotenberg for Office-to-PDF conversion.
          Required for processing Office documents alongside Tika.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3101;
        description = "Port for the Gotenberg server (default changed from 3000 to avoid Grafana conflict).";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "docker.io/gotenberg/gotenberg:8";
        description = "Container image for Gotenberg.";
      };
    };

    # ==========================================================================
    # Database Configuration
    # ==========================================================================

    database = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "PostgreSQL host.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "paperless";
        description = "Database name.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "paperless";
        description = "Database user.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing database password.";
      };

      manageDatabase = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision database via shared PostgreSQL module.";
      };

      localInstance = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether database runs on this host (adds systemd dependencies).";
      };
    };

    # ==========================================================================
    # Authentication Configuration
    # ==========================================================================

    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing admin password for initial setup.";
    };

    oidc = {
      enable = lib.mkEnableOption "OpenID Connect authentication via PocketID";

      serverUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          OIDC discovery URL (without .well-known suffix).
          Example: https://id.holthome.net/.well-known/openid-configuration
        '';
        example = "https://id.holthome.net/.well-known/openid-configuration";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "paperless";
        description = "OIDC client ID registered with PocketID.";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing OIDC client secret.";
      };

      providerId = lib.mkOption {
        type = lib.types.str;
        default = "pocketid";
        description = "Internal provider identifier for django-allauth.";
      };

      providerName = lib.mkOption {
        type = lib.types.str;
        default = "Holthome SSO";
        description = "Display name shown on login button.";
      };

      claims = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = { username = "email"; };
        description = "OIDC claim mappings.";
      };

      autoSignup = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Auto-create users on first OIDC login.";
      };

      allowSignups = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow signups via OIDC.";
      };

      autoRedirect = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically redirect to OIDC provider instead of showing login form.";
      };

      disableLocalLogin = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable username/password login (OIDC only).";
      };

      adminUser = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Username for the OIDC admin user.
          This should match the username claim from your OIDC provider.
          If using email as username (claims.username = "email"), set this to your email.
          Paperless will pre-create this user as a superuser at startup.
        '';
        example = "admin@holthome.net";
      };

      adminEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Email address for the OIDC admin user.
          Used together with adminUser to pre-create the superuser.
          If not set, defaults to the adminUser value (useful when username is email).
        '';
        example = "admin@holthome.net";
      };

      adminPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing password for the OIDC admin user.
          Required when adminUser is set to pre-create the superuser.
          The user will be able to log in with this password OR via OIDC.
        '';
        example = "/run/secrets/paperless/admin_password";
      };

      autoConnectExisting = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Automatically connect OIDC accounts to existing local accounts
          that have the same email address. This is essential for making
          OIDC users inherit permissions from pre-created admin accounts.
        '';
      };
    };

    # ==========================================================================
    # NFS Mount Configuration
    # ==========================================================================

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in modules.storage.nfsMounts to depend on.
        This ensures the NFS mount is available before paperless starts.
      '';
      example = "media";
    };

    # ==========================================================================
    # Integration Submodules
    # ==========================================================================

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for external access.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "paperless-scheduler.service";
        labels = {
          service = "paperless";
          service_type = "document_management";
        };
      };
      description = "Log shipping configuration.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Paperless service state.

        IMPORTANT: This backs up /var/lib/paperless (ZFS), NOT /mnt/data/paperless.
        Document storage on NFS is backed up by NAS snapshots separately.
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "system-alerts" ];
        };
        customMessages = {
          failure = "Paperless service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for service events.";
    };

    # ZFS integration for service state
    zfs = {
      dataset = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "tank/services/paperless";
        description = "ZFS dataset to mount at dataDir.";
      };

      recordsize = lib.mkOption {
        type = lib.types.str;
        default = "16K";
        description = "ZFS recordsize (16K optimal for SQLite/index workload).";
      };

      compression = lib.mkOption {
        type = lib.types.str;
        default = "zstd";
        description = "ZFS compression (zstd for database-heavy workload).";
      };

      properties = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "com.sun:auto-snapshot" = "true";
          atime = "off";
        };
        description = "Additional ZFS dataset properties.";
      };
    };

    # Preseed configuration for disaster recovery
    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic password file.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic.";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Order and selection of restore methods.";
      };
    };

    # Monitoring configuration
    monitoring = {
      enable = lib.mkEnableOption "monitoring for Paperless";

      prometheus = {
        enable = lib.mkEnableOption "Prometheus metrics via Node Exporter textfile collector";

        metricsDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for textfile metrics.";
        };
      };

      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:28981";
        description = "Endpoint to probe for health.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "minutely";
        description = "Healthcheck interval (systemd OnCalendar token).";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {

      # ========================================================================
      # Native Paperless Service Configuration
      # ========================================================================

      services.paperless = {
        enable = true;
        address = cfg.address;
        port = cfg.port;
        user = cfg.user;

        dataDir = cfg.dataDir;
        mediaDir = cfg.mediaDir;
        consumptionDir = cfg.consumptionDir;

        passwordFile = cfg.adminPasswordFile;

        # Database configuration
        database.createLocally = false; # We manage this via PostgreSQL module

        # Tika integration for Office documents
        configureTika = cfg.tika.enable;

        # Environment file for secrets (OIDC, database password)
        environmentFile = "/run/${serviceName}/env";

        # Main settings via environment variables
        settings = {
          # Base URL for links
          PAPERLESS_URL = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable)
            "https://${cfg.reverseProxy.hostName}";

          # Database
          PAPERLESS_DBENGINE = "postgresql";
          PAPERLESS_DBHOST = cfg.database.host;
          PAPERLESS_DBPORT = toString cfg.database.port;
          PAPERLESS_DBNAME = cfg.database.name;
          PAPERLESS_DBUSER = cfg.database.user;
          # PAPERLESS_DBPASS via environmentFile

          # OCR Configuration
          PAPERLESS_OCR_LANGUAGE = lib.concatStringsSep "+" cfg.ocr.languages;
          PAPERLESS_OCR_MODE = cfg.ocr.mode;
          PAPERLESS_OCR_CLEAN = cfg.ocr.clean;
          PAPERLESS_OCR_DESKEW = if cfg.ocr.deskew then "true" else "false";
          PAPERLESS_OCR_ROTATE_PAGES = if cfg.ocr.rotatePages then "true" else "false";
          PAPERLESS_OCR_ROTATE_PAGES_THRESHOLD = toString cfg.ocr.rotateThreshold;
          PAPERLESS_OCR_OUTPUT_TYPE = cfg.ocr.outputType;

          # Gotenberg endpoint - must match our custom port to avoid Grafana conflict
          PAPERLESS_TIKA_GOTENBERG_ENDPOINT = lib.mkIf cfg.gotenberg.enable
            "http://localhost:${toString cfg.gotenberg.port}";

          # Consumer settings
          PAPERLESS_CONSUMER_RECURSIVE = "true";
          PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = "true";

          # Export directory
          PAPERLESS_EXPORT_DIR = cfg.exportDir;

          # Timezone
          PAPERLESS_TIME_ZONE = config.time.timeZone or "UTC";

          # OIDC Configuration (when enabled)
          PAPERLESS_APPS = lib.mkIf cfg.oidc.enable
            "allauth.socialaccount.providers.openid_connect";
          PAPERLESS_SOCIAL_AUTO_SIGNUP = lib.mkIf cfg.oidc.enable
            (if cfg.oidc.autoSignup then "true" else "false");
          PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = lib.mkIf cfg.oidc.enable
            (if cfg.oidc.allowSignups then "true" else "false");
          PAPERLESS_REDIRECT_LOGIN_TO_SSO = lib.mkIf cfg.oidc.enable
            (if cfg.oidc.autoRedirect then "true" else "false");
          PAPERLESS_DISABLE_REGULAR_LOGIN = lib.mkIf cfg.oidc.enable
            (if cfg.oidc.disableLocalLogin then "true" else "false");

          # Auto-connect OIDC accounts to existing local accounts with matching email
          # This is critical for OIDC users to inherit pre-created admin privileges
          PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = lib.mkIf cfg.oidc.enable "none";
          PAPERLESS_SOCIALACCOUNT_EMAIL_AUTHENTICATION = lib.mkIf (cfg.oidc.enable && cfg.oidc.autoConnectExisting)
            "true";
          PAPERLESS_SOCIALACCOUNT_EMAIL_AUTHENTICATION_AUTO_CONNECT = lib.mkIf (cfg.oidc.enable && cfg.oidc.autoConnectExisting)
            "true";
          # PAPERLESS_SOCIALACCOUNT_PROVIDERS via environmentFile (contains secret)

          # OIDC Admin User - pre-creates superuser matching OIDC identity
          # When the user logs in via OIDC with this username, they get admin privileges
          PAPERLESS_ADMIN_USER = lib.mkIf (cfg.oidc.enable && cfg.oidc.adminUser != null)
            cfg.oidc.adminUser;
          PAPERLESS_ADMIN_MAIL = lib.mkIf (cfg.oidc.enable && cfg.oidc.adminUser != null)
            (if cfg.oidc.adminEmail != null then cfg.oidc.adminEmail else cfg.oidc.adminUser);
        };
      };

      # ========================================================================
      # Gotenberg Port Override (avoid conflict with Grafana on port 3000)
      # ========================================================================

      services.gotenberg.port = lib.mkIf cfg.gotenberg.enable cfg.gotenberg.port;

      # ========================================================================
      # Environment File Generation (secrets handling)
      # ========================================================================
      # We create a separate oneshot service to generate the environment file
      # BEFORE paperless-scheduler starts. This is needed because systemd
      # validates EnvironmentFile existence before running ExecStartPre.

      systemd.services.paperless-env = {
        description = "Paperless Environment File Generator";
        wantedBy = [ "multi-user.target" ];
        before = [ "paperless-scheduler.service" ];
        requiredBy = [ "paperless-scheduler.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = config.users.users.${cfg.user}.group;
          RuntimeDirectory = serviceName;
          RuntimeDirectoryMode = "0700";
          LoadCredential =
            (lib.optional (cfg.database.passwordFile != null)
              "db_password:${cfg.database.passwordFile}")
            ++ (lib.optional (cfg.oidc.enable && cfg.oidc.clientSecretFile != null)
              "oidc_client_secret:${cfg.oidc.clientSecretFile}")
            ++ (lib.optional (cfg.oidc.enable && cfg.oidc.adminUser != null && cfg.oidc.adminPasswordFile != null)
              "admin_password:${cfg.oidc.adminPasswordFile}");
        };

        script = ''
          set -euo pipefail
          tmp="/run/${serviceName}/env.tmp"
          trap 'rm -f "$tmp"' EXIT

          {
            ${lib.optionalString (cfg.database.passwordFile != null) ''
              printf "PAPERLESS_DBPASS=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")"
            ''}
            ${lib.optionalString (cfg.oidc.enable && cfg.oidc.clientSecretFile != null) ''
              # Build OIDC provider JSON with real secret
              oidc_secret="$(cat "$CREDENTIALS_DIRECTORY/oidc_client_secret")"
              oidc_json='${oidcProviderJson}'
              oidc_json="''${oidc_json/__OIDC_CLIENT_SECRET__/$oidc_secret}"
              printf "PAPERLESS_SOCIALACCOUNT_PROVIDERS=%s\n" "$oidc_json"
            ''}
            ${lib.optionalString (cfg.oidc.enable && cfg.oidc.adminUser != null && cfg.oidc.adminPasswordFile != null) ''
              printf "PAPERLESS_ADMIN_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
            ''}
          } > "$tmp"

          install -m 600 "$tmp" /run/${serviceName}/env
          echo "Environment file created at /run/${serviceName}/env"
        '';
      };

      systemd.services.paperless-scheduler = {
        # Ensure we wait for the environment file to be created
        after = [ "paperless-env.service" ]
          ++ lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ]
          ++ lib.optionals cfg.database.localInstance
          [ "postgresql.service" ];
        requires = [ "paperless-env.service" ]
          ++ lib.optionals cfg.database.localInstance
          [ "postgresql.service" ];
        wants = lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ];
      };

      # Also configure other paperless services
      systemd.services.paperless-consumer = {
        wants = lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ];
        after = lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ];
      };

      systemd.services.paperless-web = {
        wants = lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ];
        after = lib.optionals (cfg.nfsMountDependency != null)
          [ "${cfg.nfsMountDependency}.mount" ];
      };

      # ========================================================================
      # User Configuration
      # ========================================================================

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = lib.mkForce "/var/empty"; # Prevent 700 permission enforcement
        description = "Paperless-ngx service user";
      };

      users.groups.${cfg.group} = { };

      # NOTE: Tika and Gotenberg are handled by the native NixOS paperless module
      # via services.paperless.configureTika = true. Do NOT add container definitions
      # here as they will conflict with the native systemd services.

      # ========================================================================
      # PostgreSQL Database Provisioning
      # ========================================================================

      modules.services.postgresql.databases.${cfg.database.name} = lib.mkIf cfg.database.manageDatabase {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        extensions = [
          { name = "pg_trgm"; } # For fuzzy text search
        ];
      };

      # ========================================================================
      # ZFS Dataset Configuration
      # ========================================================================

      modules.storage.datasets.services.paperless = lib.mkIf (cfg.zfs.dataset != null) {
        mountpoint = cfg.dataDir;
        recordsize = cfg.zfs.recordsize;
        compression = cfg.zfs.compression;
        properties = cfg.zfs.properties;
        # Set ownership for ZFS dataset (native services need this since
        # StateDirectory can't manage ZFS mounts)
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # ========================================================================
      # Reverse Proxy Configuration
      # ========================================================================

      modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = cfg.reverseProxy.backend or {
          address = cfg.address;
          port = cfg.port;
        };
        # No auth at Caddy level - native OIDC handles it
      };

      # ========================================================================
      # Health Monitoring
      # ========================================================================

      systemd.services."paperless-healthcheck" = lib.mkIf cfg.monitoring.enable {
        description = "Paperless health check and metrics collector";
        serviceConfig = {
          Type = "oneshot";
          User = "node-exporter";
          Group = "node-exporter";
          ExecStart = pkgs.writeShellScript "paperless-healthcheck" ''
            set -euo pipefail

            METRICS_DIR="${cfg.monitoring.prometheus.metricsDir}"
            METRICS_FILE="$METRICS_DIR/paperless.prom"
            TMP_FILE="$METRICS_DIR/.paperless.prom.tmp"
            ENDPOINT="${cfg.monitoring.endpoint}"

            # Check if service is reachable
            if ${pkgs.curl}/bin/curl -sf --max-time 10 "$ENDPOINT" >/dev/null 2>&1; then
              up=1
            else
              up=0
            fi

            # Write metrics
            cat > "$TMP_FILE" <<EOF
            # HELP paperless_up Paperless service availability (1 = up, 0 = down)
            # TYPE paperless_up gauge
            paperless_up $up
            # HELP paperless_healthcheck_timestamp_seconds Unix timestamp of last health check
            # TYPE paperless_healthcheck_timestamp_seconds gauge
            paperless_healthcheck_timestamp_seconds $(date +%s)
            EOF

            mv "$TMP_FILE" "$METRICS_FILE"
          '';
        };
      };

      systemd.timers."paperless-healthcheck" = lib.mkIf cfg.monitoring.enable {
        description = "Timer for Paperless health check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.monitoring.interval;
          Persistent = true;
        };
      };

      # ========================================================================
      # Backup Integration
      # ========================================================================

      # Note: Only ZFS service state is backed up, NOT /mnt/data documents
      modules.backup.restic.jobs.${serviceName} = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        repository = cfg.backup.repository;
        paths = [ cfg.dataDir ];
        tags = cfg.backup.tags or [ "paperless" "document-management" "forge" ];
        excludePatterns = cfg.backup.excludePatterns or [
          "**/celery/**"
          "**/*.pyc"
          "**/__pycache__/**"
        ];
        useSnapshots = cfg.backup.useSnapshots or true;
        zfsDataset = cfg.backup.zfsDataset or cfg.zfs.dataset;
      };

      # ========================================================================
      # Preseed / Disaster Recovery
      # ========================================================================
    })

    # Preseed service (conditional)
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "paperless-scheduler.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = cfg.zfs.recordsize;
          compression = cfg.zfs.compression;
        } // cfg.zfs.properties;
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = true;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
