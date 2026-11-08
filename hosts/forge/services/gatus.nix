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

        # Use port 8090 (8080 is used by qbittorrent)
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
          # Internal access only - use admin authentication via PocketID.
          # /api/v1/endpoints is exempt: homelab-mcp's gatus_* tools read
          # endpoint status there from the k8s cluster, which cannot complete
          # the Pocket ID login (Ryan's decision, 2026-11-08). It is read-only
          # status data, on an internal-only vhost; the UI and every other
          # path keep the admin gate.
          caddySecurity = forgeDefaults.caddySecurity.admin // {
            bypassPaths = [ "/api/v1/endpoints" ];
          };
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
        owner = "gatus";
        group = "gatus";
        mode = "0750";
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

      # ── Services that moved to the k8s cluster (2026-11-08) ─────────────
      # homelab-mcp, Grafana and Grafana OnCall used to contribute these checks
      # from their own Forge modules. They now run on the cluster
      # (carpenike/k8s-gitops#5765, #5781), so Forge's Gatus checks them over
      # their public names instead: an outside view that also covers the
      # cluster's ingress and tunnel. Same keys, names and groups as before so
      # the status history carries over. Each is gated on the service NOT
      # running on Forge, so a rollback falls back to the original check.
      #
      # The OnCall check matters beyond OnCall itself: Alertmanager routes
      # every alert to OnCall (infrastructure/observability/alertmanager.nix),
      # so if OnCall is unreachable nothing pages. Gatus alerts through its
      # own Pushover provider above, not through Alertmanager, so this check
      # still pages when OnCall is the thing that is down.
      #
      # Deliberately not replaced: signal-api, schoolhouse and lading had
      # loopback-only checks (127.0.0.1) of processes that no longer exist on
      # Forge, and none of them has a public endpoint to probe. Their health is
      # the cluster's to monitor.
      modules.services.gatus.contributions = lib.mkMerge [
        (lib.mkIf (!(config.services.homelab-mcp.enable or false)) {
          # /healthz is the one route homelab-mcp serves without a bearer
          # token, and it touches no upstream, so this answers "is the public
          # path to the process open". Do not point it at /mcp (needs a JWT).
          homelab-mcp = {
            name = "Homelab MCP";
            group = "applications";
            url = "https://mcp.${config.networking.domain}/healthz";
            interval = "60s";
            conditions = [
              "[STATUS] == 200"
              "[BODY].status == ok"
              "[RESPONSE_TIME] < 5000"
            ];
            alerts = [{
              type = "pushover";
              sendOnResolved = true;
              failureThreshold = 3;
              successThreshold = 1;
            }];
          };
        })
        (lib.mkIf (!(config.modules.services.grafana.enable or false)) {
          # /api/health is unauthenticated and reports Grafana's own database.
          grafana = {
            name = "Grafana";
            group = "Monitoring";
            url = "https://grafana.${config.networking.domain}/api/health";
            interval = "60s";
            conditions = [
              "[STATUS] == 200"
              "[BODY].database == ok"
              "[RESPONSE_TIME] < 2000"
            ];
            alerts = [{
              type = "pushover";
              sendOnResolved = true;
              failureThreshold = 3;
              successThreshold = 1;
            }];
          };
        })
        (lib.mkIf (!(config.modules.services.grafana-oncall.enable or false)) {
          grafana-oncall = {
            name = "Grafana OnCall";
            group = "Monitoring";
            url = "https://oncall.${config.networking.domain}/health/";
            interval = "60s";
            conditions = [
              "[STATUS] == 200"
              "[RESPONSE_TIME] < 2000"
            ];
            alerts = [{
              type = "pushover";
              sendOnResolved = true;
              failureThreshold = 3;
              successThreshold = 2;
            }];
          };
        })
      ];

      # Custom metrics staleness alert for blackbox monitoring reliability
      modules.alerting.rules."gatus-metrics-stale" = mylib.monitoring-helpers.mkThresholdAlert {
        name = "gatus";
        alertname = "GatusMetricsStale";
        expr = ''
          (sum(increase(gatus_results_total{job="service-gatus"}[5m])) == 0)
          or absent(gatus_results_total{job="service-gatus"})
        '';
        for = "5m";
        severity = "high";
        category = "availability";
        summary = "Gatus endpoint checks are stale on {{ $labels.instance }}";
        description = "Gatus has not executed endpoint checks for over 5 minutes. The monitoring service may be frozen or overloaded.";
      };

      # Forge uses its dedicated Prometheus module rather than the observability
      # orchestrator's auto-discovered scrape targets.
      services.prometheus.scrapeConfigs = lib.optionals
        (config.modules.services.gatus.metrics.enable or false)
        [{
          job_name = "service-gatus";
          metrics_path = config.modules.services.gatus.metrics.path or "/metrics";
          scrape_interval = config.modules.services.gatus.metrics.scrapeInterval or "60s";
          scrape_timeout = config.modules.services.gatus.metrics.scrapeTimeout or "10s";
          static_configs = [{
            targets = [
              "${config.modules.services.gatus.metrics.interface or "127.0.0.1"}:${toString config.modules.services.gatus.metrics.port}"
            ];
            labels = (config.modules.services.gatus.metrics.labels or { }) // {
              host = config.networking.hostName;
              instance = "${config.networking.hostName}.${config.networking.domain}";
            };
          }];
        }];
    })
  ];
}
