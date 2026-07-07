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
    # Only scrape services with real, verified /metrics endpoints.
    # lib/service-factory.nix currently defaults metrics.enable = true for every
    # generated service even when no Prometheus endpoint exists, so an explicit
    # allowlist is required to avoid scraping dozens of dead targets.
    # TODO: drop this allowlist (reset to null) once the factory default flips
    # to metrics.enable = false and services declare metrics explicitly.
    autoDiscovery.allowedServices = [
      "gatus" # native /metrics on :8090
      "loki" # native /metrics on :3100
      "promtail" # native /metrics on :9080
    ];
    # Enable default stack alerts (Loki/Promtail health)
    alerts.enable = true;
  };
}
