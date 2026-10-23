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
    # TODO(nixos-26.05): BLOCKER - NEEDS DECISION. nixpkgs 26.05 removed both
    # services.promtail and pkgs.promtail (EOL upstream). Disabled here only so
    # the rest of the 26.05 upgrade can be evaluated. Merging this as-is stops
    # journal + Omada relay log shipping to Loki (see ./promtail.nix). Migrate
    # that pipeline to Grafana Alloy (already running here for Faro) first.
    promtail.enable = false;
  };
}
