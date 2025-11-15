{ ... }:

{
  # Enable unified Alertmanager-based alerting system
  # Handles notification routing and delivery (Pushover, etc.)
  # Prometheus configuration lives in monitoring.nix
  modules.alerting = {
    enable = true;

    # Local Alertmanager on forge
    alertmanager.url = "http://127.0.0.1:9093";

    # External URLs for alert links (via Caddy reverse proxy)
    alertmanager.externalUrl = "https://alertmanager.forge.holthome.net";
    prometheus.externalUrl = "https://prometheus.forge.holthome.net";

    # Pushover receiver: these names must match secrets.sops.yaml keys
    receivers.pushover = {
      tokenSecret = "pushover/token";
      userSecret = "pushover/user-key";
    };

    # Dead man's switch - Healthchecks.io receiver for Watchdog alert
    receivers.healthchecks = {
      urlSecret = "monitoring/healthchecks-url";
    };

    # Alert rules are defined co-located with services via modules.alerting.rules
    # This keeps them modular and DRY
    # Example: modules.alerting.rules."sonarr-failure" = { type = "event"; ... };
  };

  # Alertmanager self-monitoring alert
  modules.alerting.rules."alertmanager-down" = {
    type = "promql";
    alertname = "AlertmanagerDown";
    expr = "up{job=\"alertmanager\"} == 0";
    for = "5m";
    severity = "high";
    labels = { service = "monitoring"; category = "alertmanager"; };
    annotations = {
      summary = "Alertmanager is down on {{ $labels.instance }}";
      description = "Alert delivery system is not functioning. Check alertmanager.service status.";
    };
  };

  # Note: Prometheus configuration has been moved to monitoring.nix
  # This file only handles Alertmanager (notification routing/delivery)
}
