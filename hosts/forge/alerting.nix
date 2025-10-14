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

    # Alert rules are defined co-located with services via modules.alerting.rules
    # This keeps them modular and DRY
    # Example: modules.alerting.rules."sonarr-failure" = { type = "event"; ... };
  };

  # Note: Prometheus configuration has been moved to monitoring.nix
  # This file only handles Alertmanager (notification routing/delivery)
}
