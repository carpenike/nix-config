{ ... }:

{
  # Observability Stack - Centralized monitoring, alerting, logging, and visualization
  # This directory consolidates all observability infrastructure components:
  # - Prometheus: Metrics collection, storage, and alerting
  # - Alertmanager: Alert routing and notification delivery
  # - Grafana: Metrics and logs visualization dashboards
  # - Loki: Log aggregation and storage
  # - Promtail: Log shipping and collection agent

  imports = [
    ./prometheus.nix
    ./alertmanager.nix
    ./grafana.nix
    ./loki.nix
    ./promtail.nix
  ];

  # Enable the observability module system
  modules.services.observability = {
    enable = true;
    # Disable Prometheus in observability module since forge uses legacy configuration
    # in prometheus.nix (direct services.prometheus config)
    prometheus.enable = false;
  };
}
