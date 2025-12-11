# hosts/forge/services/termix.nix
#
# Host-specific configuration for Termix SSH web terminal on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/termix/default.nix
#
# Termix provides:
# - SSH terminal access via web browser
# - SSH tunnel management
# - Remote file manager
# - Server statistics dashboard
# - OIDC authentication via PocketID

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.termix.enable or false;
  serviceDomain = "termix.${config.networking.domain}";
in
{
  config = lib.mkMerge [
    {
      # Note: OIDC is configured via Termix Admin UI, not environment variables.
      # Termix stores OIDC config in its SQLite database.

      modules.services.termix = {
        enable = true;

        # Pin container image (Renovate will update)
        image = "ghcr.io/lukegus/termix:release-1.9.0@sha256:42649d815da4ee2cb71560b04a22641e54d993e05279908711d9056504487feb";

        # Port 8095 (8080 conflicts with qbittorrent/tqm)
        port = 8095;

        # Reverse proxy configuration (LAN only - no Cloudflare tunnel)
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          # No caddySecurity since Termix has native OIDC
        };

        # Enable backups
        backup = forgeDefaults.backup;

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore from backups
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/termix" =
        forgeDefaults.mkSanoidDataset "termix";

      # Service-specific monitoring alert
      modules.alerting.rules."termix-service-down" =
        forgeDefaults.mkServiceDownAlert "termix" "Termix" "SSH web terminal";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.termix = {
        group = "Infrastructure";
        name = "Termix";
        icon = "terminal";
        href = "https://${serviceDomain}";
        description = "SSH web terminal & server management";
        siteMonitor = "http://localhost:8095";
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.termix = {
        name = "Termix";
        group = "Infrastructure";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}
