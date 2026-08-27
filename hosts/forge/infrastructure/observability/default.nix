{ ... }:

{
  # Observability Stack - Centralized monitoring, alerting, logging, and visualization
  # This directory consolidates all observability infrastructure components:
  # - Prometheus: Metrics collection, storage, and alerting (configured in prometheus.nix)
  # - Alertmanager: Alert routing and notification delivery
  # - Grafana: Metrics and logs visualization dashboards
  # - Loki: Log aggregation and storage
  # - Promtail: Log shipping and collection agent
  # - Alloy: Browser telemetry (Grafana Faro RUM) receiver -> Loki

  imports = [
    ./prometheus.nix
    ./alertmanager.nix
    ./grafana.nix
    ./loki.nix
    ./promtail.nix
    ./alloy.nix
  ];

  # Enable the thin observability orchestrator
  # This just wires Promtail → Loki and configures Grafana datasources
  # All service-specific configuration is done directly in the individual *.nix files above
  modules.services.observability = {
    enable = true;
    # Prometheus is configured directly in prometheus.nix using services.prometheus
    prometheus.enable = false;
    # Enable default stack alerts (Loki/Promtail health)
    alerts.enable = true;
  };
}
