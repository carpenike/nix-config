# qui - Modern qBittorrent Web Interface
#
# qui provides a modern React-based web interface for qBittorrent with:
# - Multi-instance support (manage multiple qBittorrent servers)
# - Client proxy feature (eliminates auth thrashing for Sonarr/Radarr/autobrr)
# - Built-in cross-seeding with hardlink/reflink support
# - Built-in qBittorrent backup/restore
# - Native OIDC authentication (integrates with PocketID)
# - Prometheus metrics
#
# Architecture:
# - Container: ghcr.io/autobrr/qui
# - Storage: ZFS dataset at tank/services/qui
# - Authentication: PocketID OIDC (native qui support)
# - Reverse Proxy: Caddy (https://qui.holthome.net)
# - Backup: Restic + Sanoid snapshots
#
# Cross-Seed Setup (replaces standalone cross-seed daemon):
# 1. In qui UI → Instance Settings, enable "Local filesystem access" on qBittorrent instance
# 2. Go to Cross-Seed → Rules → Hardlink/Reflink Mode
# 3. Enable "Hardlink mode" for the qBittorrent instance
# 4. Set base directory to "/data/qb/cross-seeds" (on same filesystem as /data/qb/downloads)
# 5. Configure directory preset: "By Tracker" recommended
# 6. Categories: "Add .cross category suffix" to prevent *arr import loops
# 7. Add indexers in Cross-Seed → Indexers (import from Prowlarr)
# 8. Enable desired cross-seed sources: RSS Automation, Seeded Search, Completion Search
#
# Post-Deployment Steps:
# 1. Access https://qui.holthome.net
# 2. Authenticate via PocketID OIDC
# 3. After first login, manually edit /var/lib/qui/config.toml:
#    [oidc]
#    client_secret = "/run/secrets/oidc_client_secret"
# 4. Restart qui service: systemctl restart podman-qui.service
# 5. Add qBittorrent instance (localhost:8080 with credentials)
# 6. Enable Local filesystem access for the instance
# 7. Create client proxy API keys in Settings → Client Proxy Keys
# 8. Update Sonarr/Radarr/autobrr to use qui proxy URLs
# 9. Configure cross-seed hardlink mode (see above)

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  domain = config.networking.domain;
  serviceEnabled = config.modules.services.qui.enable or false;
in
{
  config = lib.mkMerge [
    # PocketID client registration handled in the PocketID admin console (client: "qui")
    # Configure qui service
    {
      modules.services.qui = {
        enable = true;

        # Use latest stable version with digest pinning (managed by Renovate)
        image = "ghcr.io/autobrr/qui:v1.14.0@sha256:5211b9444599fc7c8c98dde86bbc3c0fc7819550e36d0c4e731af2d5310139e8";

        # Basic configuration
        port = 7476;
        hostAddress = "0.0.0.0"; # Bind to all interfaces for port mapping to work
        baseUrl = "/";
        timezone = "America/New_York";
        logLevel = "INFO";

        # Native OIDC authentication via PocketID
        oidc = {
          enabled = true;
          issuer = "https://id.${domain}";
          clientId = "qui";
          clientSecretFile = config.sops.secrets."qui/oidc-client-secret".path;
          redirectUrl = "https://qui.${domain}/api/auth/oidc/callback";
          disableBuiltInLogin = false; # Allow built-in login for initial setup and admin tasks
        };

        # External programs security
        # Allow specific scripts for integration (adjust as needed)
        externalProgramAllowList = [
          # Add paths to allowed executables if using external program feature
          # Example: "/usr/local/bin/custom-script"
        ];

        # Check for updates
        checkForUpdates = true;

        # Podman network for media services communication
        podmanNetwork = "media-services"; # Enable DNS resolution to qBittorrent and other media services

        # Volume mounts for cross-seed hardlink mode
        # qui needs filesystem access to create hardlinks for cross-seeded torrents
        # Mount /mnt/data as /data to match qBittorrent's internal paths
        extraVolumes = [
          "/mnt/data:/data:rw" # qBittorrent downloads at /data/qb/downloads
          "/mnt/media:/mnt/media:rw" # Media library for hardlink destination
        ];

        # Hairpin NAT workaround: container can't reach 10.20.0.30, so override DNS
        # to point id.holthome.net to the podman bridge IP where Caddy also listens
        extraHosts = {
          "id.${domain}" = "10.89.0.1";
        };

        # Resource limits - 7d peak (12M) × 2.5 = 128M minimum
        resources = {
          memory = "128M";
          memoryReservation = "64M";
          cpus = "0.5";
        };

        # Health check
        healthcheck = {
          enable = true;
          interval = "30s";
          timeout = "10s";
          retries = 3;
          startPeriod = "30s";
        };

        # Caddy reverse proxy
        reverseProxy = {
          enable = true;
          hostName = "qui.${domain}";
          # No Authelia forward_auth or basic auth needed - qui handles auth via native OIDC
          auth = null; # Disabled because qui has native OIDC
          security = {
            hsts = {
              enable = true;
              maxAge = 15552000;
              includeSubDomains = true;
            };
            customHeaders = {
              "X-Frame-Options" = "SAMEORIGIN"; # Allow iframes from same origin
              "X-Content-Type-Options" = "nosniff";
              "Referrer-Policy" = "strict-origin-when-cross-origin";
            };
          };
        };

        # Prometheus metrics
        metricsEnabled = true;
        metricsPort = 9074;
        metricsHost = "127.0.0.1";

        metrics = {
          enable = true;
          port = 9074;
          path = "/metrics";
          labels = {
            service = "qui";
            service_type = "torrent-management";
            exporter = "qui";
          };
        };

        # Logging
        logging = {
          enable = true;
          driver = "journald";
        };

        # Notifications
        notifications = {
          enable = true;
          channels = {
            onFailure = [ "media-alerts" ];
          };
          customMessages = {
            failure = "qui qBittorrent web interface failed on ${config.networking.hostName}";
          };
        };

        # Backup configuration
        backup = forgeDefaults.backup;

        # Preseed/DR configuration
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for qui (managed by modules.storage)
      modules.storage.datasets.services.qui = {
        mountpoint = "/var/lib/qui";
        recordsize = "16K"; # Optimal for SQLite
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable sanoid snapshots
        };
        owner = "980";
        group = "media";
        mode = "0750"; # Allow group read access for backup systems
      };

      # Co-located ZFS snapshot & replication (Sanoid/Syncoid)
      modules.backup.sanoid.datasets."tank/services/qui" =
        forgeDefaults.mkSanoidDataset "qui";

      # Co-located Service Monitoring
      modules.alerting.rules."qui-service-down" =
        forgeDefaults.mkServiceDownAlert "qui" "Qui" "qBittorrent web interface";
    })
  ];
}
