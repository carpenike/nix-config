# Secondary AdGuardHome DNS resolver for the home network.
#
# luna (10.20.0.15) is the primary resolver; until now it was the ONLY
# resolver, making DNS a single point of failure (e.g. during luna's nightly
# auto-upgrade reboot). nixpi runs an independent second instance with the
# same upstreams and filtering defaults, imported directly from luna's config
# so the two stay mirrored declaratively.
#
# NOTES:
# - No runtime sync of UI-made changes between the instances yet. If drift
#   becomes a problem, deploy adguardhome-sync (follow-up).
# - The web UI binds 127.0.0.1:3000 (module-enforced) and nixpi has no
#   holthome.net reverse proxy, so reach it via an SSH tunnel:
#     ssh -L 3000:127.0.0.1:3000 nixpi   →  http://localhost:3000
# - MANUAL STEP: add nixpi's IP as the secondary DNS server in the Mikrotik
#   DHCP server settings (and any static DNS client configs).
# - MANUAL STEP: add `networking/adguardhome/password` to
#   hosts/nixpi/secrets.sops.yaml (see ./secrets.nix).
{ config, lib, ... }:
{
  imports = [
    # nixpi's flake service categories don't include "network", so import the
    # AdGuardHome module directly.
    ../../modules/nixos/services/adguardhome
  ];

  config = {
    modules.services.adguardhome = {
      enable = true;
      mutableSettings = true; # Allow web UI changes to persist
      # Mirror luna's essential settings (upstreams, local holthome.net/holtel.io
      # routing via Mikrotik, blocklists, client VLAN policies).
      settings = import ../luna/config/adguard.nix { inherit config lib; };
      # No reverseProxy: nixpi's Caddy only serves holtel.io (see ./caddy.nix)
    };

    # DNS service ports (web UI stays localhost-only)
    networking.firewall = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
  };
}
