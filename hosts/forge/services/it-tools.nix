# hosts/forge/services/it-tools.nix
#
# Host-specific configuration for IT-Tools on 'forge'.
# IT-Tools provides a collection of web-based developer utilities.
#
# This service is completely stateless - no ZFS dataset, backup, or preseed needed.
# Access is LAN-only (no Cloudflare Tunnel, no authentication).

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.it-tools.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.it-tools = {
        enable = true;

        # Canonical image pin (Renovate manages host-level pins; module default is an unpinned fallback)
        image = "ghcr.io/home-operations/it-tools:2024.10.22@sha256:7f26ae8d7a4a58b8d70b685cba5cbaa54d7df876d9f8bae702207f45b06d9b7c";

        # Reverse proxy configuration for LAN access via Caddy
        # No authentication required - open access on local network
        reverseProxy = {
          enable = true;
          hostName = "it-tools.${config.networking.domain}";
          # No caddySecurity - intentionally open for LAN users
        };

        # Enable health checking
        healthcheck.enable = true;
      };
    }

    (lib.mkIf serviceEnabled {
      # Service-specific monitoring alert
      # Uses container service active check since IT-Tools is a Podman container
      modules.alerting.rules."it-tools-service-down" =
        forgeDefaults.mkServiceDownAlert "it-tools" "IT-Tools" "developer utilities";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.it-tools = {
        group = "Tools";
        name = "IT-Tools";
        icon = "it-tools";
        href = "https://it-tools.${config.networking.domain}";
        description = "Web-based developer utilities";
        siteMonitor = "http://localhost:${toString config.modules.services.it-tools.port}";
      };

      # Gatus black-box monitoring contribution
      # User-facing availability check
      modules.services.gatus.contributions.it-tools = {
        name = "IT-Tools";
        group = "Tools";
        url = "http://localhost:${toString config.modules.services.it-tools.port}";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
      };

      # Note: No ZFS dataset, backup, or Sanoid configuration needed
      # IT-Tools is completely stateless - all tools run client-side
    })
  ];
}
