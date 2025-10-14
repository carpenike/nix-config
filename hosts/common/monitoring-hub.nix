# Common monitoring hub configuration
#
# This profile defines the "monitoring hub" role for a host. It sets up
# the central Prometheus server.
#
# To use it, import this file into a host's configuration and then specify
# the `services.prometheus.scrapeConfigs` for that instance.
#
# NOTE: This does NOT enable Alertmanager. The alerting module should be
# enabled and configured in the host-specific alerting.nix file.
{ config, ... }:

{
  # Central Prometheus SERVER configuration.
  services.prometheus = {
    enable = true;

    # Prometheus listens on localhost only (not exposed externally via this service).
    listenAddress = "127.0.0.1";
    port = 9090;

    # External URL for Prometheus (used in alert links and UI)
    # Can be overridden in host-specific configuration if alerting module sets it
    webExternalUrl = config.modules.alerting.prometheus.externalUrl or null;

    # Explicit retention policy (multi-model consensus recommendation)
    # 15 days provides sufficient history for homelab troubleshooting, capacity trends, and dashboards
    # Longer retention not needed: configs in Git, metrics are disposable/regenerate automatically
    retentionTime = "15d";

    # Global scrape/evaluation cadence.
    globalConfig = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
      external_labels = {
        # Label metrics with the hostname of the monitoring server itself.
        instance = config.networking.hostName;
        environment = "homelab";
      };
    };

    # ruleFiles should be set in the host-specific configuration
    # to avoid circular dependencies with the alerting module.
    # See hosts/forge/monitoring.nix for an example.
  };
}
