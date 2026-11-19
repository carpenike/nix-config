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

        # Pin container image with digest for immutability.
        #
        # Held on 1.x by a version tag, not `latest`: tududi 2.0 runs on
        # PostgreSQL only and refuses to start on the 1.x SQLite database in
        # /app/backend/db ("A tududi 1.x SQLite database was found"). The
        # `latest` digest bump in #1442 pulled 2.1.1 and the unit failed on
        # 2026-11-18. This is the amd64 image of 1.9.7, the digest that ran
        # before #1442. With a semver tag, Renovate's automerged minor/digest
        # updates stay on 1.x and 2.x arrives as an unmerged major PR. Moving
        # to 2.x needs the data migrated to PostgreSQL first.
        image = "chrisvel/tududi:1.9.8@sha256:6b481bfab5e8d1fec07e5539992992b9f7a400755b6e0957e8b470fa791dde29";

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
        backup = forgeDefaults.mkBackupWithSnapshots "tududi";

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
