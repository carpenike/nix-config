# hosts/forge/services/paperless.nix
#
# Host-specific configuration for Paperless-ngx on 'forge'.
# Paperless-ngx is a self-hosted document management system with OCR.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "paperless.${domain}";
  dataset = "tank/services/paperless";
  dataDir = "/var/lib/paperless";
  pocketIdIssuer = "https://id.${domain}";
  listenAddr = "127.0.0.1";
  listenPort = 28981;
  serviceEnabled = config.modules.services.paperless.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.paperless = {
        enable = true;

        # Service binding
        address = listenAddr;
        port = listenPort;

        # Storage paths
        # - dataDir: ZFS dataset for service state (index, thumbnails, db)
        # - mediaDir/consumptionDir/exportDir: NFS mount for documents (NAS handles backup)
        dataDir = dataDir;
        mediaDir = "/mnt/data/paperless/media";
        consumptionDir = "/mnt/data/paperless/consume";
        exportDir = "/mnt/data/paperless/export";

        # NFS mount dependency for document storage
        nfsMountDependency = "mnt-data";

        # OCR configuration (English + German as requested)
        ocr = {
          languages = [ "eng" "deu" ];
          mode = "skip"; # Skip OCR if document already has text
          deskew = true;
          rotatePages = true;
        };

        # Enable Office document processing
        tika.enable = true;
        gotenberg.enable = true;

        # Database configuration via shared PostgreSQL module
        database = {
          host = "localhost";
          port = 5432;
          name = "paperless";
          user = "paperless";
          passwordFile = config.sops.secrets."paperless/database_password".path;
          manageDatabase = true;
          localInstance = true;
        };

        # Admin password for initial setup
        adminPasswordFile = config.sops.secrets."paperless/admin_password".path;

        # Native OIDC via PocketID (following mealie pattern)
        oidc = {
          enable = true;
          serverUrl = "${pocketIdIssuer}/.well-known/openid-configuration";
          clientId = "paperless";
          clientSecretFile = config.sops.secrets."paperless/oidc_client_secret".path;
          providerId = "pocketid";
          providerName = "Holthome SSO";
          claims = {
            username = "email";
          };
          autoSignup = true;
          allowSignups = true;
          autoRedirect = true; # Auto-redirect to PocketID (OIDC account now linked)
          disableLocalLogin = false; # Keep local login as fallback

          # Pre-create admin user matching OIDC identity
          # When you log in via PocketID with this email, you'll have admin privileges
          adminUser = "ryan@ryanholt.net"; # Must match your PocketID email
          adminPasswordFile = config.sops.secrets."paperless/admin_password".path;
        };

        # Reverse proxy via Caddy
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = listenAddr;
            port = listenPort;
          };
        };

        # ZFS dataset for service state
        zfs = {
          dataset = dataset;
          recordsize = "16K"; # Optimal for SQLite/FTS5 index workload
          compression = "zstd";
          properties = {
            "com.sun:auto-snapshot" = "true";
            atime = "off";
          };
        };

        # Backup ONLY service state (ZFS), NOT document storage (NFS)
        # NAS handles its own snapshots for /mnt/data/paperless
        backup = forgeDefaults.mkBackupWithTags "paperless" [ "documents" "paperless" "forge" ];

        # Notifications
        notifications.enable = true;

        # Health monitoring
        monitoring = {
          enable = true;
          prometheus.enable = true;
          endpoint = "http://${listenAddr}:${toString listenPort}";
          interval = "minutely";
        };

        # Preseed for disaster recovery (ZFS state only)
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication for service state dataset
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "paperless";

      # Cloudflare Tunnel for external access
      modules.services.caddy.virtualHosts.paperless.cloudflare = {
        enable = true;
        tunnel = "forge";
      };

      # Homepage dashboard contribution
      modules.services.homepage.contributions.paperless = {
        group = "Productivity";
        name = "Paperless";
        icon = "paperless-ngx";
        href = "https://${serviceDomain}";
        description = "Document management system";
        siteMonitor = "http://${listenAddr}:${toString listenPort}";
        widget = {
          type = "paperlessngx";
          url = "http://${listenAddr}:${toString listenPort}";
          key = "{{HOMEPAGE_VAR_PAPERLESS_TOKEN}}";
        };
      };

      # Gatus endpoint monitoring
      modules.services.gatus.contributions.paperless = {
        name = "Paperless";
        group = "applications";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };

      # Service availability alert
      modules.alerting.rules."paperless-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "paperless-scheduler" "Paperless" "document management";
    })
  ];
}
