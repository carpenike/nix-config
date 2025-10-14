{ lib, config, ... }:

{
  imports = [
    # This host is a standard monitored agent.
    ../common/monitoring-agent.nix
    # This host is also designated as the central monitoring hub.
    ../common/monitoring-hub.nix
  ];

  # Host-specific overrides for the node-exporter agent on 'forge'.
  # This is kept here because the backup metrics are specific to 'forge'.
  services.prometheus.exporters.node = {
    # Add the textfile collector for custom backup metrics.
    # Note: monitoring-agent.nix already enables [ "systemd" ], so we override with both
    enabledCollectors = lib.mkForce [ "systemd" "textfile" ];
    # Specify the directory for the textfile collector.
    extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector" ];
  };

  # Note: The monitoring module creates the textfile_collector directory with correct permissions (2770 prometheus-node-exporter)

  # Define the scrape targets for this instance of the monitoring hub.
  # If the hub were moved to another host, this block would move with it.
  services.prometheus = {
    # Wire Prometheus to Alertmanager for alert delivery
    alertmanagers = [{
      static_configs = [{
        targets = [ "127.0.0.1:9093" ];
      }];
      scheme = "http";
    }];

    # Load alert rules from the alerting module
    # Rules are co-located with services and automatically aggregated
    ruleFiles = [ config.modules.alerting.prometheus.ruleFilePath ];

    scrapeConfigs = [
      # Node exporter (system metrics + textfile collectors)
      {
        job_name = "node";
        # List all hosts that this Prometheus instance should scrape.
        static_configs = [
          { targets = [ "127.0.0.1:9100" ]; labels = { instance = "forge"; }; }
          # Example for when other hosts are added:
          # { targets = [ "luna.holthome.net:9100" ]; labels = { instance = "luna"; }; }
          # { targets = [ "nas-1.holthome.net:9100" ]; labels = { instance = "nas-1"; }; }
        ];
      }

      # Prometheus self-monitoring
      {
        job_name = "prometheus";
        static_configs = [
          { targets = [ "127.0.0.1:9090" ]; labels = { instance = "forge"; }; }
        ];
      }

      # Alertmanager monitoring
      {
        job_name = "alertmanager";
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; labels = { instance = "forge"; }; }
        ];
      }
    ];
  };
}
