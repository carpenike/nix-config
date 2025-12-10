# hosts/forge/services/miniflux.nix
#
# Host-specific configuration for Miniflux on 'forge'.
# Miniflux is a minimalist, self-hosted RSS feed reader.
#
# OIDC Admin Note:
# Miniflux does NOT support OIDC claims-based admin role mapping.
# To create an admin user linked to OIDC:
# 1. Enable adminCredentials to create an initial admin
# 2. Log in via OIDC with your email
# 3. Link accounts via: miniflux-cli -user-id=N -set-admin
# 4. Disable adminCredentials after linking

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "miniflux.${domain}";
  dataset = "tank/services/miniflux";
  dataDir = "/var/lib/miniflux";
  pocketIdIssuer = "https://id.${domain}";
  listenAddr = "127.0.0.1";
  listenPort = 8381;
  serviceEnabled = config.modules.services.miniflux.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.miniflux = {
        enable = true;

        # Service binding
        listenAddress = listenAddr;
        port = listenPort;

        # Storage paths
        dataDir = dataDir;

        # Use local PostgreSQL (native module handles createDatabaseLocally)
        database = {
          createLocally = true;
        };

        # Admin credentials - DISABLED after OIDC admin linked
        # Re-enable temporarily if you need to recover admin access
        adminCredentials = {
          enable = false;
          credentialsFile = config.sops.secrets."miniflux/admin_credentials".path;
        };

        # Native OIDC via PocketID
        # Note: Miniflux automatically appends .well-known/openid-configuration
        # so we provide just the issuer URL
        oidc = {
          enable = true;
          discoveryEndpoint = pocketIdIssuer;
          clientId = "miniflux";
          clientSecretFile = config.sops.secrets."miniflux/oidc_client_secret".path;
          providerName = "Holthome SSO";
          userCreation = true;
          disableLocalAuth = false; # Keep local auth for admin fallback
        };

        # Enable Prometheus metrics collector
        metricsCollector = {
          enable = true;
          allowedNetworks = [ "127.0.0.1/8" "10.69.0.0/16" ];
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
          properties = {
            recordsize = "16K"; # Optimal for PostgreSQL socket path workload
            compression = "zstd";
            "com.sun:auto-snapshot" = "true";
            atime = "off";
          };
        };

        # Backup configuration
        backup = forgeDefaults.mkBackupWithTags "miniflux" [ "rss" "miniflux" "productivity" "forge" ];

        # Notifications
        notifications.enable = true;

        # Preseed for disaster recovery
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Metrics for Prometheus scraping
        metrics = {
          enable = true;
          port = listenPort;
          path = "/metrics";
          labels = {
            service_type = "rss";
            function = "feed-reader";
          };
        };

        # Logging for Loki
        logging = {
          enable = true;
          journalUnit = "miniflux.service";
          labels = {
            service = "miniflux";
            service_type = "rss";
          };
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication for service state dataset
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "miniflux";

      # Cloudflare Tunnel for external access
      modules.services.caddy.virtualHosts.miniflux.cloudflare = {
        enable = true;
        tunnel = "forge";
      };

      # Homepage dashboard contribution
      modules.services.homepage.contributions.miniflux = {
        group = "Productivity";
        name = "Miniflux";
        icon = "miniflux";
        href = "https://${serviceDomain}";
        description = "RSS feed reader";
        siteMonitor = "http://${listenAddr}:${toString listenPort}";
        widget = {
          type = "miniflux";
          url = "http://${listenAddr}:${toString listenPort}";
          key = "{{HOMEPAGE_VAR_MINIFLUX_TOKEN}}";
        };
      };

      # Gatus endpoint monitoring
      modules.services.gatus.contributions.miniflux = {
        name = "Miniflux";
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
      modules.alerting.rules."miniflux-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "miniflux" "Miniflux" "RSS feed reader";
    })
  ];
}
