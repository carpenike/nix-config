{ ... }:

{
  # Observability Stack - Centralized monitoring, alerting, logging, and visualization
  # This directory consolidates all observability infrastructure components:
  # - Prometheus: Metrics collection, storage, and alerting (configured in prometheus.nix)
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

  # Enable the thin observability orchestrator
  # This just wires Promtail → Loki and configures Grafana datasources
  # All service-specific configuration is done directly in the individual *.nix files above
  modules.services.observability = {
    enable = true;
    # Prometheus is configured directly in prometheus.nix using services.prometheus.
    # Auto-discovery still contributes scrape configs to that native hub (the
    # observability module appends discovered jobs to services.prometheus.scrapeConfigs).
    prometheus.enable = false;
    # No allowlist: the service factory defaults metrics.enable = false, so a
    # service appearing in discovery is an explicit, trustworthy declaration
    # that it exposes a real Prometheus endpoint (gatus/loki/promtail today,
    # autobrr via its module-level metrics option).
    # Enable default stack alerts (Loki/Promtail health)
    alerts.enable = true;
  };
}
