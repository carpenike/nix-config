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
    alertmanager.externalUrl = "https://am.holthome.net";
    prometheus.externalUrl = "https://prom.holthome.net";

    # Pushover receiver: these names must match secrets.sops.yaml keys
    receivers.pushover = {
      tokenSecret = "pushover/token";
      userSecret = "pushover/user-key";
    };

    # Dead man's switch - Healthchecks.io receiver for Watchdog alert
    receivers.healthchecks = {
      urlSecret = "monitoring/healthchecks-url";
    };

    # Alerta - Alert consolidation and deduplication dashboard
    # Sends all alerts to Alerta in parallel with Pushover for visual dashboard
    receivers.alerta = {
      enable = true;
      url = "http://127.0.0.1:5000/api/webhooks/prometheus";
      # Note: No apiKeyFile - using unauthenticated internal webhook
      # Alerta is internal-only and protected by reverse proxy + OIDC
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

  # Declare Alertmanager storage dataset (contribution pattern)
  # Rationale (GPT-5 validated):
  # - Only stores silences and notification deduplication state
  # - Homelab acceptable to lose silences on restart
  # - Duplicate notifications after restart are tolerable
  # - Dedicated dataset unnecessary for minimal administrative state
  # Location: /var/lib/alertmanager on tank/services/alertmanager (not snapshotted)
  modules.storage.datasets.services.alertmanager = {
    recordsize = "16K"; # Small files; minimal overhead
    compression = "lz4"; # Fast, default
    mountpoint = "/var/lib/alertmanager";
    owner = "alertmanager";
    group = "alertmanager";
    mode = "0750";
    properties = {
      "com.sun:auto-snapshot" = "false"; # Do not snapshot (non-critical state)
      logbias = "throughput";
      primarycache = "metadata";
      atime = "off";
    };
  };

  # Declare Alertmanager Sanoid policy (no snapshots for non-critical state)
  modules.backup.sanoid.datasets."tank/services/alertmanager" = {
    autosnap = false;
    autoprune = false;
    recursive = false;
  };
}
