# Joins the tailnet as tag:mx-edge (k8s-gitops docs/platform/tailscale.md).
# The tailnet policy grants that tag only tcp:2525 on the cluster's mail
# address, reached through the Connector's subnet route, so the route has to
# be accepted here.
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
  };

  networking.firewall = {
    # SSH and the Stalwart WebUI over the tailnet (see stalwart.nix).
    interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    # Tailscale's direct connections.
    allowedUDPPorts = [ config.services.tailscale.port ];
    checkReversePath = "loose";
  };
}
