# Common monitoring agent configuration for all hosts in the homelab.
# This configures node-exporter to be scraped by a central Prometheus server.
{ ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    # Listen on all interfaces to be reachable from the central Prometheus server.
    listenAddress = "0.0.0.0";
    # Open the standard node-exporter port.
    openFirewall = true;
    # A sane set of default collectors for all hosts.
    # Host-specific collectors can be appended in the host's configuration.
    enabledCollectors = [ "systemd" ];
  };
}
