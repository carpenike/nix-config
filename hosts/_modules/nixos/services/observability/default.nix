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

      # Filter services that have metrics enabled
      servicesWithMetrics = lib.filterAttrs
        (_name: service:
          (service.metrics or null) != null &&
          (service.metrics.enable or false)
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
    alerts = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable default alerting rules for Loki and Promtail";
      };

      rules = mkOption {
        type = types.listOf types.attrs;
        default = [
          {
            alert = "LokiNoLogsIngested";
            expr = "rate(loki_distributor_bytes_received_total[5m]) == 0";
            for = "10m";
            labels = { severity = "warning"; service = "loki"; };
            annotations = {
              summary = "Loki is not ingesting logs";
              description = "No logs have been ingested by Loki in the last 10 minutes";
            };
          }
          {
            alert = "LokiQueryErrors";
            expr = "increase(loki_querier_queries_failed_total[5m]) > 0";
            for = "5m";
            labels = { severity = "warning"; service = "loki"; };
            annotations = {
              summary = "Loki query failures detected";
              description = "{{ $value }} query failures in the last 5 minutes";
            };
          }
          {
            alert = "PromtailDroppingLogs";
            expr = "increase(promtail_client_dropped_bytes_total[5m]) > 0";
            for = "5m";
            labels = { severity = "critical"; service = "promtail"; };
            annotations = {
              summary = "Promtail is dropping logs";
              description = "Promtail has dropped {{ $value }} bytes of logs in the last 5 minutes";
            };
          }
        ];
        description = "Default alerting rules for the observability stack";
      };
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
    services.prometheus = mkIf cfg.prometheus.enable {
      enable = true;
      scrapeConfigs = discoveredScrapeConfigs ++ cfg.autoDiscovery.staticTargets;
      globalConfig = lib.mkDefault {
        scrape_interval = "15s";
        evaluation_interval = "15s";
        external_labels = {
          instance = config.networking.hostName;
          environment = "homelab";
        };
      };
    };

    # CLI tools for log analysis
    environment.systemPackages =
      (lib.optional cfg.loki.enable pkgs.grafana-loki) ++
      (lib.optional cfg.grafana.enable pkgs.grafana);
  };
}
