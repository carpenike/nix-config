# Observability and monitoring services
# Import this category for hosts that need monitoring capabilities
{ ... }:
{
  imports = [
    ../beszel # Server monitoring (hub + agent)
    ../gatus # Black-box monitoring / status page
    ../glances # System monitoring dashboard
    ../gpu-metrics # GPU metrics exporter
    ../grafana # Visualization dashboards
    ../grafana-oncall # Incident response platform
    ../loki # Log aggregation
    ../node-exporter # Host metrics exporter
    ../observability # Unified observability stack
    ../promtail # Log shipping agent
  ];
}
