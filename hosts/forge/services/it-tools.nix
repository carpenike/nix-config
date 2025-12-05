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

        # Pin container image with digest for immutability
        # Renovate bot can be configured to automate updates
        image = "corentinth/it-tools:latest@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f";

        # Reverse proxy configuration for LAN access via Caddy
        # No authentication required - open access on local network
        reverseProxy = {
          enable = true;
          hostName = "it-tools.holthome.net";
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
        href = "https://it-tools.holthome.net";
        description = "Web-based developer utilities";
        siteMonitor = "http://localhost:8380";
      };

      # Gatus black-box monitoring contribution
      # User-facing availability check
      modules.services.gatus.contributions.it-tools = {
        name = "IT-Tools";
        group = "Tools";
        url = "http://localhost:8380";
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
