# Metrics for the cluster's Prometheus (k8s-gitops docs/apps/mail.md,
# "Monitoring the edge"). It scrapes node-exporter on 9100 and Stalwart's
# /metrics/prometheus on 8080 through a Tailscale egress proxy (tag:k8s).
# The tailnet policy grants that tag tcp:8080 and tcp:9100 on tag:mx-edge.
#
# Not hosts/common/monitoring-agent.nix: it opens 9100 on every interface,
# and this VM has a public address. Here the exporter listens on all
# addresses but the firewall admits 9100 on tailscale0 only, the same way
# stalwart.nix admits 8080. The Vultr firewall group blocks it publicly as
# a second layer.
{ ... }:
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "0.0.0.0";
    openFirewall = false;
    # Unit states for the alerts on nixos-upgrade.service and
    # podman-stalwart.service.
    enabledCollectors = [ "systemd" ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9100 ];
}
