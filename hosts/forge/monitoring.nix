{ ... }:

{
  # Enable monitoring using common module with host-specific configuration
  modules.monitoring = {
    enable = true;

    nodeExporter = {
      enable = true;
      # Port 9100 is standard for node-exporter (uses module default)

      # Security: Listen on all interfaces for internal network access
      # Forge is on internal network (10.20.0.0/24) only
      listenAddress = "0.0.0.0";

      # Security: Explicitly enable firewall for Prometheus scraping
      # Safe because forge is behind router firewall on internal network
      openFirewall = true;

      # Enable additional collectors for backup server monitoring
      enabledCollectors = [ "systemd" "textfile" ];

      # Enable textfile collector for custom backup metrics
      # The backup module writes metrics to this directory
      textfileCollector = {
        enable = true;
        directory = "/var/lib/node_exporter/textfile_collector";
      };
    };
  };
}
