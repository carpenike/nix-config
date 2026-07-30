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
  # Bind to localhost only - no container dependencies identified
  # External access via Caddy reverse proxy
  listenAddr = "127.0.0.1";
  listenPort = 28981;
  # Use multiple workers to prevent single-request blocking
  # Granian workers can hang under certain conditions (known NixOS issue)
  # More workers = resilience if one hangs. With 16 cores/32GB, 6 is conservative.
  granianWorkers = 6;
  taskWorkers = 2;
  threadsPerWorker = 2;
  consumerPollingSeconds = 10;
  serviceEnabled = config.modules.services.paperless.enable or false;
  documentBackup = repository: {
    enable = true;
    inherit repository;
    paths = [
      "/mnt/data/paperless/media"
      "/mnt/data/paperless/consume"
    ];
    tags = [ "documents" "paperless" "originals" ];
    excludePatterns = [ "**/thumbnails/**" ];
    frequency = "daily";
    useSnapshots = false;
    zfsDataset = null;
  };
in
{
  config = lib.mkMerge [
    {
      services.paperless.settings = {
        # Prevent a single blocking request from hanging the web service.
        GRANIAN_WORKERS = toString granianWorkers;
        # Bound OCR concurrency at four cores so other forge workloads remain responsive.
        PAPERLESS_TASK_WORKERS = toString taskWorkers;
        PAPERLESS_THREADS_PER_WORKER = toString threadsPerWorker;
        # NFS does not reliably propagate inotify events to the consumer.
        PAPERLESS_CONSUMER_POLLING = toString consumerPollingSeconds;
        # Keep raw archive paths understandable outside the application.
        PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ document_type }}/{{ title }}";
        PAPERLESS_FILENAME_FORMAT_REMOVE_NONE = "true";
        # Recognize ASN labels for physical originals without enabling page splitting.
        PAPERLESS_CONSUMER_ENABLE_ASN_BARCODE = "true";
        PAPERLESS_CONSUMER_ASN_BARCODE_PREFIX = "ASN";
      };

      modules.services.paperless = {
        enable = true;

        # Service binding
        address = listenAddr;
        port = listenPort;

        # Storage paths
        # - dataDir: ZFS dataset for service state (index, thumbnails, db)
        # - mediaDir/consumptionDir: NFS mount for documents and scanner intake
        # - exportDir: local ZFS for portable application-level exports
        dataDir = dataDir;
        mediaDir = "/mnt/data/paperless/media";
        consumptionDir = "/mnt/data/paperless/consume";
        exportDir = "${dataDir}/export";

        consumer = {
          recursive = true;
          # Paperless-AI owns the managed taxonomy; scanner folders must not create tags.
          subdirsAsTags = false;
        };

        exporter = {
          enable = true;
          # Portable recovery layer; daily raw media/database backups remain authoritative.
          onCalendar = "Sun *-*-* 00:30:00";
        };

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

        # Backup service state from its local ZFS snapshot. Document originals
        # are protected separately by the NAS1 and R2 jobs below.
        backup = forgeDefaults.mkBackupWithTags "paperless" [ "documents" "paperless" "forge" ];

        # Notifications
        notifications.enable = true;

        # Health monitoring
        monitoring = {
          enable = true;
          prometheus.enable = true;
          endpoint = "http://${listenAddr}:${toString listenPort}";
          interval = "minutely";
          tokenFile = config.sops.secrets."paperless-ai/paperless_token".path;
        };

        # Preseed for disaster recovery (ZFS state only)
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };

      # Increase shutdown timeout for Granian - default 90s is insufficient
      # Granian sometimes takes longer to drain connections gracefully
      systemd.services.paperless-web.serviceConfig.TimeoutStopSec = "120s";
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication for service state dataset
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "paperless";

      # The live document tree is on the legacy NAS, outside forge's ZFS
      # snapshot boundary. Keep independent encrypted copies on NAS1 and R2.
      modules.services.backup.restic.jobs = {
        paperless-documents-nas = documentBackup "nas-primary";
        paperless-documents-r2 = documentBackup "r2-offsite";
      };

      systemd.services = {
        restic-backup-paperless-documents-nas = {
          requires = [ "mnt-data.mount" ];
          after = [ "mnt-data.mount" ];
        };
        restic-backup-paperless-documents-r2 = {
          requires = [ "mnt-data.mount" ];
          after = [ "mnt-data.mount" ];
        };
      };

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

      modules.alerting.rules = {
        "paperless-web-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "paperless-web" "PaperlessWeb" "web interface";
        "paperless-consumer-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "paperless-consumer" "PaperlessConsumer" "document consumer";
        "paperless-task-queue-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "paperless-task-queue" "PaperlessTaskQueue" "background task queue";
        "paperless-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "paperless-scheduler" "Paperless" "document scheduler";
        "paperless-tika-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "tika" "PaperlessTika" "Office document parser";
        "paperless-gotenberg-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "gotenberg" "PaperlessGotenberg" "document converter";

        "paperless-deep-health-unavailable" = {
          type = "promql";
          alertname = "PaperlessDeepHealthUnavailable";
          expr = "paperless_deep_health_up == 0";
          for = "5m";
          severity = "high";
          labels = { service = "paperless"; category = "availability"; };
          annotations = {
            summary = "Paperless authenticated health endpoint is unavailable";
            description = "The /api/status/ health check failed or its API token was rejected.";
          };
        };

        "paperless-component-unhealthy" = {
          type = "promql";
          alertname = "PaperlessComponentUnhealthy";
          expr = "paperless_deep_health_up == 1 and paperless_component_up == 0";
          for = "5m";
          severity = "high";
          labels = { service = "paperless"; category = "dependency"; };
          annotations = {
            summary = "Paperless {{ $labels.component }} health check failed";
            description = "Paperless reports an unhealthy internal component.";
          };
        };

        "paperless-failed-tasks" = {
          type = "promql";
          alertname = "PaperlessFailedTasks";
          expr = "paperless_unacknowledged_failed_tasks > 0";
          for = "10m";
          severity = "medium";
          labels = { service = "paperless"; category = "processing"; };
          annotations = {
            summary = "Paperless has unacknowledged failed tasks";
            description = "Review failed document-processing tasks in the Paperless administration UI.";
          };
        };

        "paperless-exporter-failed" = {
          type = "promql";
          alertname = "PaperlessExporterFailed";
          expr = ''node_systemd_unit_state{name="paperless-exporter.service",state="failed"} == 1'';
          for = "5m";
          severity = "high";
          labels = { service = "paperless"; category = "backup"; };
          annotations = {
            summary = "Paperless portable exporter failed";
            description = "The weekly application-level export did not complete.";
          };
        };

        "paperless-healthcheck-stale" = {
          type = "promql";
          alertname = "PaperlessHealthcheckStale";
          expr = "absent(paperless_healthcheck_timestamp_seconds) or (time() - paperless_healthcheck_timestamp_seconds > 300)";
          for = "5m";
          severity = "high";
          labels = { service = "paperless"; category = "monitoring"; };
          annotations = {
            summary = "Paperless healthcheck metrics are stale";
            description = "No Paperless healthcheck result has been published for over five minutes.";
          };
        };
      };
    })
  ];
}
