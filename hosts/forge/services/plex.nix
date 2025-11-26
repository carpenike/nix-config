# hosts/forge/services/plex.nix
#
# Host-specific configuration for the Plex Media Server on 'forge'.
# Plex provides media streaming and library management.

{ lib, config, mylib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.plex.enable or false;
in
{
  config = lib.mkMerge [
    {
      # Enable Plex via modular service
      modules.services.plex = {
        enable = true;

        # Reverse proxy integration via Caddy
        reverseProxy = {
          enable = true;
          hostName = "plex.holthome.net";
        };

        # ZFS dataset management for Plex data
        zfs = {
          dataset = "tank/services/plex";
          recordsize = "128K";
          compression = "lz4";
          properties = {
            "com.sun:auto-snapshot" = "true";  # Enable for backup snapshot coordination
            atime = "off";
          };
        };

        # Backup Plex application data daily to NAS repo
        # Rationale (Gemini Pro 2.5 validated): Watch history and metadata changes occur
        # daily with active users. The pain of losing up to 7 days of user activity
        # (watch history, collections, preferences) outweighs the minimal incremental
        # backup cost due to Restic deduplication. Daily backups provide acceptable
        # DR RPO while ZFS snapshots (every 5min) handle immediate rollback needs.
        backup = {
          enable = true;
          repository = "nas-primary";
          frequency = "daily";  # Changed from weekly per Gemini Pro recommendation
          tags = [ "plex" "media-metadata" "forge" ];
          # CRITICAL: Enable ZFS snapshots for SQLite database consistency
          useSnapshots = true;
          zfsDataset = "tank/services/plex";
          # Exclude non-critical directories and security-sensitive files
          excludePatterns = [
            "**/Plex Media Server/Cache/**"
            "**/Plex Media Server/Logs/**"
            "**/Plex Media Server/Crash Reports/**"
            "**/Plex Media Server/Updates/**"
            "**/Transcode/**"
            # Exclude security-sensitive files created by Plex with 600 permissions
            # These files cannot be read by restic-backup user (even with group membership)
            # Both files are non-critical: .LocalAdminToken is ephemeral, Setup Plex.html is static
            "**/Plex Media Server/.LocalAdminToken"
            "**/Plex Media Server/Setup Plex.html"
          ];
        };

        # Enable health monitoring and textfile metrics
        monitoring = {
          enable = true;
          prometheus.enable = true;  # Node exporter textfile collector is enabled in monitoring.nix
          endpoint = "http://127.0.0.1:32400/web";
          interval = "minutely";
        };

        # Enable preseed for disaster recovery using forgeDefaults
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Plex dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/plex" =
        forgeDefaults.mkSanoidDataset "plex";

      # Prometheus alerts for Plex
      # Using monitoring-helpers library for consistency
      modules.alerting.rules = {
        # Service availability alert using standard helper
        "plex-down" = mylib.monitoring-helpers.mkThresholdAlert {
          name = "plex";
          alertname = "PlexDown";
          expr = "plex_up == 0";
          threshold = 0;
          for = "5m";
          severity = "critical";
          category = "availability";
          summary = "Plex is down on {{ $labels.instance }}";
          description = "Plex healthcheck failing. Check service: systemctl status plex.service";
        };

        # Healthcheck staleness alert using forgeDefaults helper
        "plex-healthcheck-stale" = forgeDefaults.mkHealthcheckStaleAlert "plex" "Plex" 600;
      };
    })
  ];
}
