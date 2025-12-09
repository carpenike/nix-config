# hosts/forge/services/pinchflat.nix
#
# Host-specific configuration for the Pinchflat YouTube media manager on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/pinchflat/default.nix
#
# Pinchflat downloads YouTube videos based on channel/playlist subscriptions.
# Media is stored on NFS share at /mnt/data/youtube for access by other services.
#
# SOPS secrets are defined in hosts/forge/secrets.nix (pinchflat/env)

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.pinchflat.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.pinchflat = {
        enable = true;

        # Store config/database on ZFS, downloads on NFS
        dataDir = "/var/lib/pinchflat";
        mediaDir = "/mnt/data/media/youtube";

        # User configuration - UID 930, media group for NFS access
        user = "pinchflat";
        uid = 930;
        group = "media";

        # NFS mount dependency for media storage
        nfsMountDependency = "media";

        # ZFS dataset for SQLite database (optimized recordsize)
        zfs = {
          enable = true;
          dataset = "tank/services/pinchflat";
          recordsize = "16K"; # Optimal for SQLite
          compression = "lz4";
        };

        # Secrets file with SECRET_KEY_BASE and optionally YOUTUBE_API_KEY
        # Defined in secrets.nix
        secretsFile = config.sops.secrets."pinchflat/env".path;

        # Enable Prometheus metrics
        extraConfig = {
          ENABLE_PROMETHEUS = true;
        };

        # Reverse proxy configuration for external access via Caddy
        reverseProxy = {
          enable = true;
          hostName = "pinchflat.holthome.net";

          # Protect via PocketID; grant "media" role
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        # Prometheus metrics (native /metrics endpoint)
        metrics = {
          enable = true;
          port = 8945;
          path = "/metrics";
          labels = {
            service_type = "media";
            exporter = "pinchflat";
            function = "youtube-downloader";
          };
        };

        # Enable backups via the unified backup system
        backup = forgeDefaults.mkBackupWithTags "pinchflat" forgeDefaults.backupTags.media;

        # Enable self-healing restore from backups before service start
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Gatus health check
        healthCheck = {
          enable = true;
          group = "Media";
          interval = "60s";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Pinchflat dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/pinchflat" =
        forgeDefaults.mkSanoidDataset "pinchflat";

      # Service-specific monitoring alerts
      # Uses systemd alert (native service, not container)
      modules.alerting.rules."pinchflat-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "pinchflat" "Pinchflat" "YouTube media manager";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.pinchflat = {
        group = "Media";
        name = "Pinchflat";
        icon = "pinchflat";
        href = "https://pinchflat.holthome.net";
        description = "YouTube media manager";
        siteMonitor = "http://localhost:8945";
      };
    })
  ];
}
