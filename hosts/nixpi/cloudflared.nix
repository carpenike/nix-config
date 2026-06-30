# Cloudflare Tunnel for nixpi (the RV Raspberry Pi).
#
# Leverages the shared `modules.services.cloudflared` module — the same pattern
# forge uses in hosts/forge/services/cloudflare-tunnel.nix. The tunnel object and
# its credentials were created out of band in Cloudflare and live encrypted in
# secrets.sops.yaml; this file wires them into NixOS and enables the tunnel.
#
# Routing is OPT-IN: a Caddy virtualHost declares
#   cloudflare = { enable = true; tunnel = "nixpi"; };
# to be auto-discovered into the tunnel ingress and DNS. Until a vhost opts in,
# the tunnel connects but serves only `http_status:404` — nothing is publicly
# reachable. coachiq therefore stays loopback-only here; exposing iq.holtel.io
# is a separate step gated on coachiq's own auth (native PocketID OIDC, pending
# upstream) and on re-enabling Caddy with that vhost.
{ config, ... }:
{
  config = {
    # Tunnel credentials JSON (AccountTag / TunnelSecret / TunnelID) and the
    # Zone:DNS:Edit API token used for hostname auto-registration. Both are read
    # by the cloudflared service user, which the module creates.
    sops.secrets.cloudflared_tunnel_credentials = {
      mode = "0400";
      owner = config.users.users.cloudflared.name;
      group = config.users.groups.cloudflared.name;
    };
    sops.secrets.cloudflare_api_token = {
      mode = "0400";
      owner = config.users.users.cloudflared.name;
      group = config.users.groups.cloudflared.name;
    };

    modules.services.cloudflared = {
      enable = true;

      tunnels.nixpi = {
        # Tunnel UUID — not secret (the TunnelSecret stays in sops). Must match
        # the TunnelID inside cloudflared_tunnel_credentials.
        id = "5c7d98e9-4575-48e6-96ef-f2372e2b5152";

        credentialsFile = config.sops.secrets.cloudflared_tunnel_credentials.path;

        # DNS auto-registration via API token (nixpi has no origin cert).
        # zoneName MUST be explicit: nixpi does not set networking.domain, so the
        # module default (holthome.net) would be wrong — this host lives on holtel.io.
        dnsApiTokenFile = config.sops.secrets.cloudflare_api_token.path;
        dnsRegistration = {
          mode = "api";
          zoneName = "holtel.io";
        };

        # defaultService is left at the module default
        # (http://127.0.0.1:<caddy http port>) so discovered hostnames route
        # through Caddy once it is re-enabled with real vhosts.
      };
    };
  };
}
