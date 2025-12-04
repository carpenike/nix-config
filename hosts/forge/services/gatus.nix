{ config, lib, mylib, ... }:
# Gatus Configuration for forge
#
# Gatus provides black-box monitoring and status pages for homelab services.
# Replaces Uptime Kuma with a YAML-config-based, lightweight solution with native Prometheus metrics.
#
# ARCHITECTURE:
# - Native NixOS service (wrapped with homelab patterns)
# - Contributory pattern: services opt-in via gatus.contributions
# - SQLite storage on ZFS for persistence
# - Internal-only access (no Cloudflare Tunnel)
# - Pushover alerting for service failures
#
# Retains all homelab integrations: ZFS, backups, preseed, monitoring, Caddy reverse proxy.
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.gatus.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.gatus = {
        enable = true;

        # Use port 8090 (8080 is used by tqm)
        port = 8090;

        # SQLite storage (persisted on ZFS)
        storage = {
          type = "sqlite";
          path = "/var/lib/gatus/data.db";
        };

        # Pushover alerting configuration
        alerting.pushover = {
          enable = true;
          applicationTokenFile = config.sops.secrets."pushover/token".path;
          userKeyFile = config.sops.secrets."pushover/user-key".path;
          priority = 1;
          sound = "siren";
          resolvedPriority = 0;
        };

        # Status page UI customization
        ui = {
          title = "Holthome Service Status";
          header = "Status";
        };

        # Reverse proxy integration via Caddy (internal only, no Cloudflare)
        reverseProxy = {
          enable = true;
          hostName = "status.${config.networking.domain}";
          backend = {
            host = "127.0.0.1";
            port = 8090;
          };
          # Internal access only - use admin authentication via PocketID
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };

        # Prometheus metrics (Gatus has native /metrics endpoint)
        metrics = {
          enable = true;
          port = 8090;
          path = "/metrics";
          labels = {
            service = "gatus";
            service_type = "monitoring";
            function = "blackbox";
          };
        };

        # Backup using forgeDefaults helper with monitoring tags
        backup = forgeDefaults.mkBackupWithTags "gatus" (forgeDefaults.backupTags.monitoring ++ [ "gatus" "forge" ]);

        # Enable self-healing restore from backups
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf serviceEnabled {
      # ZFS dataset for service data
      modules.storage.datasets.services.gatus = {
        mountpoint = "/var/lib/gatus";
        recordsize = "16K"; # Optimal for SQLite
        compression = "lz4";
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/gatus" =
        forgeDefaults.mkSanoidDataset "gatus";

      # Service-down alert using forgeDefaults helper
      modules.alerting.rules."gatus-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "gatus" "Gatus" "status monitoring";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.gatus = {
        group = "Monitoring";
        name = "Gatus";
        icon = "gatus";
        href = "https://status.holthome.net";
        description = "Service status monitoring";
        siteMonitor = "http://localhost:8090";
      };

      # Custom metrics staleness alert for blackbox monitoring reliability
      modules.alerting.rules."gatus-metrics-stale" = mylib.monitoring-helpers.mkThresholdAlert {
        name = "gatus";
        alertname = "GatusMetricsStale";
        expr = ''time() - gatus_results_last_execution_timestamp_seconds > 300'';
        for = "5m";
        severity = "high";
        category = "availability";
        summary = "Gatus endpoint checks are stale on {{ $labels.instance }}";
        description = "Gatus has not executed endpoint checks for over 5 minutes. The monitoring service may be frozen or overloaded.";
      };
    })
  ];
}
