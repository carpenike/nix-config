# Prometheus metrics collection type definition
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized metrics collection submodule
  # Services that expose Prometheus metrics should use this type for automatic discovery
  metricsSubmodule = types.submodule {
    options = {
      enable = mkEnableOption "Prometheus metrics collection";

      port = mkOption {
        type = types.port;
        description = "Port where metrics endpoint is exposed";
        example = 9090;
      };

      path = mkOption {
        type = types.str;
        default = "/metrics";
        description = "HTTP path for the metrics endpoint";
        example = "/metrics";
      };

      interface = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Interface the metrics endpoint binds to";
      };

      scrapeInterval = mkOption {
        type = types.str;
        default = "60s";
        description = "How often Prometheus should scrape this target";
        example = "30s";
      };

      scrapeTimeout = mkOption {
        type = types.str;
        default = "10s";
        description = "Timeout for scraping this target";
      };

      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Additional static labels to apply to all metrics from this target";
        example = {
          environment = "production";
          team = "infrastructure";
          service_type = "database";
        };
      };

      relabelConfigs = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Prometheus relabel configs for advanced metric processing";
        example = [
          {
            source_labels = [ "__name__" ];
            regex = "^go_.*";
            action = "drop";
          }
        ];
      };
    };
  };
}
