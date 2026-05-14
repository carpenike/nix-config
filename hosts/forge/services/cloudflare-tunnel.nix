# Cloudflare Tunnel Configuration
# Provides secure external access to selected services via Cloudflare's network
#
# Infrastructure Contributions:
#   - Backup: Not applicable (credentials are in SOPS, no runtime state)
#   - Sanoid: Not applicable (no ZFS dataset)
#   - Monitoring: Service-down alert (native systemd service)
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.cloudflared.enable;
in
{
  # Enable Cloudflare Tunnel service
  config = lib.mkMerge [
    {
      modules.services.cloudflared = {
        enable = true;

        # Define tunnels (can have multiple for different purposes)
        tunnels.forge = {
          # Tunnel UUID from Cloudflare dashboard
          id = "349603ab-49ed-4e49-bb76-6d803d8b978e";

          # Credentials file managed by SOPS (see secrets.nix)
          # To create: cloudflared tunnel create forge
          # Then encrypt the JSON with: sops hosts/forge/secrets.sops.yaml
          credentialsFile = config.sops.secrets."networking/cloudflare/forge-credentials".path;
          originCertFile = config.sops.secrets."networking/cloudflare/origin-cert".path;

          # API token for DNS registration across multiple zones.
          # The origin cert above is per-zone (selected at `cloudflared login` time)
          # and would require re-auth whenever we add a new domain. The API token
          # path is set-and-forget: a single Cloudflare token with Zone:DNS:Edit
          # scoped to every zone we want this tunnel to manage.
          # Required permissions: Zone -> DNS -> Edit
          # Recommended Zone Resources: Include -> All zones from account
          # (or explicitly list holthome.net + whiskeywhiskeywhiskey.org).
          dnsApiTokenFile = config.sops.secrets."networking/cloudflare/tunnel-dns-api-token".path;

          # Pin DNS registration to API mode. Without this the module's "auto"
          # default would prefer CLI mode whenever originCertFile is present,
          # which only works for zones authorized into the origin cert.
          dnsRegistration.mode = "api";

          # Default backend: route all tunnel traffic through Caddy over HTTPS
          # Connecting with TLS avoids Caddy's automatic HTTP->HTTPS redirects when
          # requests arrive from Cloudflare, preventing redirect loops at the edge.
          defaultService = "https://127.0.0.1:443";

          # Optional: Enable debug logging
          # extraConfig = {
          #   "log-level" = "debug";
          # };
        };
      };
    }

    # Example: Enable external access for a service
    # Uncomment and modify as needed:
    #
    # modules.services.caddy.virtualHosts.grafana = {
    #   # ... existing configuration ...
    #   cloudflare = {
    #     enable = true;
    #     tunnel = "forge";
    #   };
    # };

    # Co-located Service Monitoring
    (lib.mkIf serviceEnabled {
      modules.alerting.rules."cloudflare-tunnel-service-down" =
        # cloudflared is a native systemd service, not a container
        forgeDefaults.mkSystemdServiceDownAlert "cloudflared" "CloudflareTunnel" "external access gateway";
    })
  ];
}
