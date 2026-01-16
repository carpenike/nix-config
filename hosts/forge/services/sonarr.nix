# hosts/forge/services/sonarr.nix
#
# Host-specific configuration for the Sonarr service on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/sonarr/default.nix

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.sonarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.sonarr = {
        enable = true;

        # Pin container image to a specific version with a digest for immutability.
        # Renovate bot can be configured to automate updates.
        image = "ghcr.io/home-operations/sonarr:4.0.16.2946@sha256:22651c750eedb091f6d76ade95dbecae0eeafe2b55432c3b8d8b042e8745f344";

        # Use shared NFS mount and attach to the media services network.
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy.
        reverseProxy = {
          enable = true;
          hostName = "sonarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant "media" role when the
          # upstream claim exposes the media group membership.
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        # Enable backups via the custom backup module integration.
        backup = forgeDefaults.backup;

        # Enable failure notifications via the custom notifications module.
        notifications.enable = true;

        # Enable self-healing restore from backups before service start.
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Sonarr dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/sonarr" =
        forgeDefaults.mkSanoidDataset "sonarr";

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."sonarr-service-down" =
        forgeDefaults.mkServiceDownAlert "sonarr" "Sonarr" "TV series management";

      # Homepage dashboard contribution
      # Service registers itself with the dashboard using the contributory pattern
      modules.services.homepage.contributions.sonarr = {
        group = "Media";
        name = "Sonarr";
        icon = "sonarr";
        href = "https://sonarr.holthome.net";
        description = "TV series management";
        siteMonitor = "http://localhost:8989";
        # Widget displays queue and series stats
        # API key injected via HOMEPAGE_VAR_SONARR_API_KEY environment variable
        widget = {
          type = "sonarr";
          url = "http://localhost:8989";
          key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
          enableQueue = true;
        };
      };
    })
  ];
}
