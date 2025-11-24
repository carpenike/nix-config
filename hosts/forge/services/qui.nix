# qui - Modern qBittorrent Web Interface
#
# qui provides a modern React-based web interface for qBittorrent with:
# - Multi-instance support (manage multiple qBittorrent servers)
# - Client proxy feature (eliminates auth thrashing for Sonarr/Radarr/autobrr)
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
# Post-Deployment Steps:
# 1. Access https://qui.holthome.net
# 2. Authenticate via PocketID OIDC
# 3. After first login, manually edit /var/lib/qui/config.toml:
#    [oidc]
#    client_secret = "/run/secrets/oidc_client_secret"
# 4. Restart qui service: systemctl restart podman-qui.service
# 5. Add qBittorrent instance (localhost:8080 with credentials)
# 6. Create client proxy API keys in Settings → Client Proxy Keys
# 7. Update Sonarr/Radarr/autobrr to use qui proxy URLs

{ config, ... }:

let
  domain = config.networking.domain;
in
{
  config = {
    # PocketID client registration handled in the PocketID admin console (client: "qui")
    # Configure qui service
    modules.services.qui = {
      enable = true;

      # Use latest stable version with digest pinning (managed by Renovate)
      image = "ghcr.io/autobrr/qui:v1.7.0@sha256:af6faa0aea35497c66f9460d5460c421d57c017e04163295f904af952b103d9a";

      # Basic configuration
      port = 7476;
      hostAddress = "0.0.0.0";  # Bind to all interfaces for port mapping to work
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
        disableBuiltInLogin = false;  # Allow built-in login for initial setup and admin tasks
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
      podmanNetwork = "media-services";  # Enable DNS resolution to qBittorrent and other media services

      # Resource limits
      resources = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "1.0";
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
        auth = null;  # Disabled because qui has native OIDC
        security = {
          hsts = {
            enable = true;
            maxAge = 15552000;
            includeSubDomains = true;
          };
          customHeaders = {
            "X-Frame-Options" = "SAMEORIGIN";  # Allow iframes from same origin
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

      # Preseed/DR configuration
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        environmentFile = config.sops.secrets."restic/r2-prod-env".path;
        restoreMethods = [ "syncoid" "local" "restic" ];
      };
    };

    # ZFS dataset for qui (managed by modules.storage)
    modules.storage.datasets.services.qui = {
      mountpoint = "/var/lib/qui";
      recordsize = "16K";  # Optimal for SQLite
      compression = "zstd";
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable sanoid snapshots
      };
      owner = "980";
      group = "media";
      mode = "0750";  # Allow group read access for backup systems
    };

    # Note: Backup integration now handled by backup-integration module
    # The backup submodule configuration will be auto-discovered and converted
    # to a Restic job named "service-qui" with the specified settings

    # Co-located Service Monitoring
    modules.alerting.rules."qui-service-down" = {
      type = "promql";
      alertname = "QuiServiceInactive";
      expr = "container_service_active{name=\"qui\"} == 0";
      for = "2m";
      severity = "high";
      labels = { service = "qui"; category = "availability"; };
      annotations = {
        summary = "qui service is down on {{ $labels.instance }}";
        description = "The qui qBittorrent web interface service is not active.";
        command = "systemctl status podman-qui.service";
      };
    };
  };
}
