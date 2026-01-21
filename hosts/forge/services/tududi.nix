# hosts/forge/services/tududi.nix
#
# Host-specific configuration for the Tududi service on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/tududi/default.nix

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.tududi.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.tududi = {
        enable = true;

        # Pin container image with digest for immutability
        image = "chrisvel/tududi:latest@sha256:5212ca3fb5309cab626cd3b3f0f85182685b4a6df4d1030b18349824255057a5";

        # Admin credentials
        adminEmail = "ryan@ryanholt.net";
        adminPasswordFile = config.sops.secrets."tududi/admin_password".path;
        sessionSecretFile = config.sops.secrets."tududi/session_secret".path;

        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy
        reverseProxy = {
          enable = true;
          hostName = "tududi.holthome.net";

          # No SSO integration - Tududi uses built-in multi-user authentication
          # Users will authenticate directly with Tududi's session-based auth
        };

        # Enable backups via the custom backup module integration
        backup = forgeDefaults.backup;

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore from backups before service start
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Tududi dataset
      modules.backup.sanoid.datasets."tank/services/tududi" =
        forgeDefaults.mkSanoidDataset "tududi";

      # Service-specific monitoring alerts
      modules.alerting.rules."tududi-service-down" =
        forgeDefaults.mkServiceDownAlert "tududi" "Tududi" "Task and productivity management";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.tududi = {
        group = "Productivity";
        name = "Tududi";
        icon = "tududi";
        href = "https://tududi.holthome.net";
        description = "Task and project management";
        siteMonitor = "http://localhost:3005";
      };

      # Gatus monitoring contribution
      modules.services.gatus.contributions.tududi = {
        name = "Tududi";
        group = "Productivity";
        url = "https://tududi.holthome.net";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 3000"
        ];
      };
    })
  ];
}
