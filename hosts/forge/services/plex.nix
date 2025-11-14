{ lib, config, mylib, ... }:
{
  config = {
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

      # Enable preseed for disaster recovery
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        # environmentFile not needed for local filesystem repository
        restoreMethods = [ "syncoid" "local" "restic" ];
      };
    };

    # Prometheus alerts for Plex
    # Using monitoring-helpers library for consistency
    modules.alerting.rules = lib.mkIf (config.modules.services.plex.enable) {
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

      # Healthcheck staleness - custom alert (no helper fits this pattern)
      "plex-healthcheck-stale" = {
        type = "promql";
        alertname = "PlexHealthcheckStale";
        expr = "time() - plex_last_check_timestamp > 600";
        # Guard against timer jitter and brief executor delays
        for = "2m";
        severity = "high";
        labels = { service = "plex"; category = "availability"; };
        annotations = {
          summary = "Plex healthcheck stale on {{ $labels.instance }}";
          description = "No healthcheck updates for >10 minutes. Verify timer: systemctl status plex-healthcheck.timer";
        };
      };
    };
  };
}
