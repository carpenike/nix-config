{ lib, config, ... }:
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
          "com.sun:auto-snapshot" = "false";
          atime = "off";
        };
      };

      # Backup Plex application data weekly to NAS repo
      backup = {
        enable = true;
        repository = "nas-primary";
        frequency = "weekly";
        tags = [ "plex" "media-metadata" "forge" ];
      };

      # Enable health monitoring and textfile metrics
      monitoring = {
        enable = true;
        prometheus.enable = true;  # Node exporter textfile collector is enabled in monitoring.nix
        endpoint = "http://127.0.0.1:32400/web";
        interval = "minutely";
      };
    };

    # Prometheus alerts for Plex
    modules.alerting.rules = lib.mkIf (config.modules.services.plex.enable) {
      "plex-down" = {
        type = "promql";
        alertname = "PlexDown";
        expr = "plex_up == 0";
        for = "5m";
        severity = "critical";
        labels = { service = "plex"; category = "availability"; };
        annotations = {
          summary = "Plex is down on {{ $labels.instance }}";
          description = "Plex healthcheck failing. Check service: systemctl status plex.service";
        };
      };

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
