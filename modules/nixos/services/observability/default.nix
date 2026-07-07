# Thin Observability Orchestrator
#
# This module provides a simple "enable the observability stack" toggle that:
# - Enables and wires together Loki, Promtail, Grafana, and optionally Prometheus
# - Configures auto-discovery of service metrics
# - Wires Promtail → Loki and Grafana datasources automatically
#
# It does NOT re-expose individual service options. Users who need to customize
# Loki retention, Grafana OIDC, Promtail scrape configs, etc. should configure
# those directly on the individual modules:
#   - modules.services.loki.*
#   - modules.services.promtail.*
#   - modules.services.grafana.*
#   - services.prometheus.*
#
# This follows the "thin orchestrator" pattern recommended by flake-parts and
# NixOS module best practices.
#
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mapAttrsToList;
  cfg = config.modules.services.observability;

  # Auto-discovery function for services with metrics submodules
  # Uses safe pattern to avoid nix store path issues and infinite recursion
  discoverMetricsTargets = config:
    let
      # Extract all modules.services.* configurations (excluding observability to prevent recursion)
      allServices = lib.filterAttrs (name: _service: name != "observability") (config.modules.services or { });

      # Filter services that are enabled and have metrics enabled.
      #
      # IMPORTANT (metrics trust model): discovery must only scrape services that
      # actually expose a Prometheus endpoint. lib/service-factory.nix currently
      # defaults metrics.enable = true for every generated service even though most
      # apps (sonarr, radarr, plex, ...) have no native /metrics endpoint — that
      # default should flip to false so metrics.enable becomes an explicit,
      # trustworthy declaration. Until then, hosts can constrain discovery with
      # autoDiscovery.allowedServices (see option description below).
      servicesWithMetrics = lib.filterAttrs
        (name: service:
          (service.enable or false) &&
          (service.metrics or null) != null &&
          (service.metrics.enable or false) &&
          (cfg.autoDiscovery.allowedServices == null
            || lib.elem name cfg.autoDiscovery.allowedServices)
        )
        allServices;

      # Convert to Prometheus scrape_config format
      # `host` matches Loki's host label for cross-system correlation
      # `instance` uses FQDN for Prometheus-native patterns
      scrapeConfigs = mapAttrsToList
        (serviceName: service: {
          job_name = "service-${serviceName}";
          static_configs = [{
            targets = [ "${service.metrics.interface or "127.0.0.1"}:${toString service.metrics.port}" ];
            labels = (service.metrics.labels or { }) // {
              service = serviceName;
              host = config.networking.hostName;
              instance = "${config.networking.hostName}.${config.networking.domain or "local"}";
            };
          }];
          metrics_path = service.metrics.path or "/metrics";
          scrape_interval = service.metrics.scrapeInterval or "60s";
          scrape_timeout = service.metrics.scrapeTimeout or "10s";
          relabel_configs = service.metrics.relabelConfigs or [ ];
        })
        servicesWithMetrics;
    in
    scrapeConfigs;

  # Generate discovered scrape configurations
  discoveredScrapeConfigs =
    if cfg.autoDiscovery.enable
    then discoverMetricsTargets config
    else [ ];
in
{
  options.modules.services.observability = {
    enable = mkEnableOption "observability stack (Loki + Promtail + Grafana)";

    # Component toggles - default to enabled when stack is enabled
    loki.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.modules.services.observability.enable";
      description = "Enable Loki log aggregation server";
    };

    promtail.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.modules.services.observability.enable";
      description = "Enable Promtail log shipping agent";
    };

    grafana.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.modules.services.observability.enable";
      description = "Enable Grafana monitoring dashboard";
    };

    prometheus.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable Prometheus metrics server via observability module.
        Note: Set to false by default as Prometheus is often configured
        directly via services.prometheus for more control.
      '';
    };

    # Stack-level configuration (truly cross-cutting concerns)
    autoDiscovery = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable automatic discovery of service metrics endpoints";
      };

      allowedServices = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [ "gatus" "loki" "promtail" ];
        description = ''
          Optional allowlist of service names (attribute names under
          modules.services.*) that auto-discovery may scrape. When null, every
          enabled service with metrics.enable = true is scraped.

          This exists because lib/service-factory.nix currently defaults
          metrics.enable = true for all generated services, including ones with
          no real /metrics endpoint. Hosts should set an explicit allowlist
          until that default flips to false, after which this can be reset to
          null.
        '';
      };

      staticTargets = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Additional static scrape targets for Prometheus";
        example = [{
          job_name = "node-exporter";
          static_configs = [{
            targets = [ "localhost:9100" ];
          }];
        }];
      };
    };

    # Default alerting rules for the stack
    # Rules are contributed to modules.alerting.rules (rendered into the
    # Prometheus rule file by the alerting module) and require the Loki and
    # Promtail metrics endpoints to be scraped (see auto-discovery above).
    alerts.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable default alerting rules for Loki and Promtail health";
    };
  };

  config = mkIf cfg.enable {
    # Enable individual services - they configure themselves
    modules.services.loki.enable = mkIf cfg.loki.enable true;
    modules.services.promtail.enable = mkIf cfg.promtail.enable true;
    modules.services.grafana.enable = mkIf cfg.grafana.enable true;

    # Wire Promtail to local Loki instance
    modules.services.promtail.lokiUrl = mkIf (cfg.promtail.enable && cfg.loki.enable)
      "http://127.0.0.1:${toString config.modules.services.loki.port}";

    # Auto-configure Grafana datasources (use mkDefault so host config can override)
    modules.services.grafana.autoConfigure = mkIf cfg.grafana.enable {
      loki = lib.mkDefault cfg.loki.enable;
      prometheus = lib.mkDefault cfg.prometheus.enable;
    };

    # Prometheus configuration with auto-discovery
    #
    # Scrape configs are contributed whenever a Prometheus server runs on this
    # host — either the bundled one (cfg.prometheus.enable) or a natively
    # configured hub (services.prometheus.enable set elsewhere, e.g.
    # hosts/forge/infrastructure/observability/prometheus.nix). This lets hosts
    # keep full control of the Prometheus server while still consuming the
    # per-service metrics auto-discovery (list options merge, so discovered
    # jobs are appended to any host-defined scrapeConfigs).
    services.prometheus = lib.mkMerge [
      (mkIf cfg.prometheus.enable {
        enable = true;
        globalConfig = lib.mkDefault {
          scrape_interval = "15s";
          evaluation_interval = "15s";
          external_labels = {
            instance = config.networking.hostName;
            environment = "homelab";
          };
        };
      })
      (mkIf (cfg.autoDiscovery.enable && (cfg.prometheus.enable || config.services.prometheus.enable)) {
        scrapeConfigs = discoveredScrapeConfigs ++ cfg.autoDiscovery.staticTargets;
      })
    ];

    # Default observability stack alerts (contribution pattern)
    # These are PromQL rules over Loki/Promtail's own metrics, so they only
    # provide signal when those endpoints are scraped (auto-discovery above).
    modules.alerting.rules = mkIf cfg.alerts.enable (lib.mkMerge [
      (mkIf cfg.loki.enable {
        "loki-no-logs-ingested" = {
          type = "promql";
          alertname = "LokiNoLogsIngested";
          expr = "sum(rate(loki_distributor_bytes_received_total[5m])) == 0";
          for = "10m";
          severity = "medium";
          labels = { service = "loki"; category = "observability"; };
          annotations = {
            summary = "Loki is not ingesting logs";
            description = "No logs have been ingested by Loki in the last 10 minutes. Check promtail.service and loki.service.";
          };
        };
        "loki-query-errors" = {
          type = "promql";
          alertname = "LokiQueryErrors";
          expr = "increase(loki_querier_queries_failed_total[5m]) > 0";
          for = "5m";
          severity = "medium";
          labels = { service = "loki"; category = "observability"; };
          annotations = {
            summary = "Loki query failures detected";
            description = "{{ $value }} Loki query failures in the last 5 minutes. Check loki.service logs.";
          };
        };
      })
      (mkIf cfg.promtail.enable {
        "promtail-dropping-logs" = {
          type = "promql";
          alertname = "PromtailDroppingLogs";
          # promtail_dropped_bytes_total is the client-side drop counter
          # (the previously used promtail_client_dropped_bytes_total does not exist)
          expr = "increase(promtail_dropped_bytes_total[5m]) > 0";
          for = "5m";
          severity = "critical";
          labels = { service = "promtail"; category = "observability"; };
          annotations = {
            summary = "Promtail is dropping logs";
            description = "Promtail has dropped {{ $value }} bytes of logs in the last 5 minutes. Check Loki availability and Promtail backpressure.";
          };
        };
      })
    ]);

    # CLI tools for log analysis
    environment.systemPackages =
      (lib.optional cfg.loki.enable pkgs.grafana-loki) ++
      (lib.optional cfg.grafana.enable pkgs.grafana);
  };
}
