# Joins the tailnet as tag:mx-edge (k8s-gitops docs/platform/tailscale.md).
# The tailnet policy grants that tag only tcp:2525 on the cluster's mail
# address, reached through the Connector's subnet route, so the route has to
# be accepted here.
#
# Tailnet DNS stays off: MagicDNS splits holthome.net to the MikroTik, which
# this tag may not reach, so every lookup under it hung until timeout. A
# mail edge also needs the public view of the zone. dns.nix resolves instead.
{ config, ... }:
{
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/auth_key".path;
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--advertise-tags=tag:mx-edge"
      "--accept-routes"
    ];
    # Applied on every start, unlike extraUpFlags, which only the first
    # login uses.
    extraSetFlags = [ "--accept-dns=false" ];
  };

  networking.firewall = {
    # SSH and the Stalwart WebUI over the tailnet (see stalwart.nix).
    interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    # Tailscale's direct connections.
    allowedUDPPorts = [ config.services.tailscale.port ];
    checkReversePath = "loose";
  };
}
