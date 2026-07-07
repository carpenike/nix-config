# Apprise API - Notification gateway for Forge
#
# Internal notification routing service allowing services like Tracearr to send
# notifications to Pushover and other notification platforms via HTTP API.
#
# Configuration:
#   1. Deploy this service
#   2. Access https://apprise.holthome.net to configure notification URLs
#   3. Add Pushover URL: pover://{user_key}@{api_token}
#   4. Configure services to use http://127.0.0.1:8000/notify/default
#
{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.apprise.enable or false;

  serviceDomain = "apprise.${config.networking.domain}";
in
{
  config = lib.mkMerge [
    {
      modules.services.apprise = {
        enable = true;

        # Canonical image pin (Renovate manages host-level pins; module default is an unpinned fallback)
        image = "docker.io/caronc/apprise:1.3.0@sha256:e365025a7bf1fed39ef66b5f22c9855d500ee7bdea27441365e5b95ea972e843";

        # Simple stateful mode - URLs stored by key name
        statefulMode = "simple";

        # Single worker sufficient for homelab
        workerCount = 1;

        # Enable web admin UI for managing notification URLs
        enableAdmin = true;

        # Reverse proxy for web admin access
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          # Admin interface should be protected
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };

        # Standard backup config
        backup = forgeDefaults.backup;

        # Preseed for disaster recovery
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot/replication config
      modules.backup.sanoid.datasets."tank/services/apprise" =
        forgeDefaults.mkSanoidDataset "apprise";

      # Service down alert
      modules.alerting.rules."apprise-service-down" =
        forgeDefaults.mkServiceDownAlert "apprise" "Apprise" "notification gateway";

      # Homepage dashboard entry
      modules.services.homepage.contributions.apprise = {
        group = "Infrastructure";
        name = "Apprise";
        icon = "apprise";
        href = "https://${serviceDomain}";
        description = "Notification gateway";
        siteMonitor = "http://127.0.0.1:${toString config.modules.services.apprise.port}/status";
      };

      # Gatus health check
      modules.services.gatus.contributions.apprise = {
        name = "Apprise";
        group = "Infrastructure";
        url = "http://127.0.0.1:${toString config.modules.services.apprise.port}/status";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}
