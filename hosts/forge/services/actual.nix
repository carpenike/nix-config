# hosts/forge/services/actual.nix
#
# Host-specific configuration for Actual Budget on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/actual/default.nix
#
# Actual Budget is a privacy-focused personal finance app.
# Uses native OIDC via PocketID for authentication.
# Internal only - no Cloudflare Tunnel (finance data is sensitive).

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.actual.enable or false;

  # Service configuration values - single source of truth
  serviceName = "actual";
  port = 5006; # Actual Budget default port
  hostName = "budget.${config.networking.domain}";
  externalUrl = "https://${hostName}";
  internalUrl = "http://127.0.0.1:${toString port}";
in
{
  config = lib.mkMerge [
    {
      modules.services.actual = {
        enable = true;
        port = port;

        # Native OIDC authentication via PocketID
        oidc = {
          enable = true;
          discoveryUrl = "https://id.holthome.net/.well-known/openid-configuration";
          clientId = "actual-budget";
          clientSecretFile = config.sops.secrets."actual/oidc-client-secret".path;
          serverHostname = externalUrl;
          # authMethod = "openid"; # Use "oauth2" if you get openid-grant-failed errors
        };

        # Reverse proxy configuration for external access via Caddy
        # No caddySecurity needed - using native OIDC
        reverseProxy = {
          enable = true;
          hostName = hostName;
          backend = {
            host = "127.0.0.1";
            port = port;
          };
        };

        # Backup configuration
        backup = forgeDefaults.backup;

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore from backups
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for Actual data
      # Must set owner/group/mode explicitly - StateDirectory can't change
      # permissions on pre-existing ZFS mountpoints
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = "/var/lib/actual";
        recordsize = "16K"; # SQLite database workload
        compression = "lz4";
        owner = config.modules.services.actual.user;
        group = config.modules.services.actual.group;
        mode = "0750";
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/${serviceName}" =
        forgeDefaults.mkSanoidDataset serviceName;

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert serviceName "Actual" "personal finance";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.${serviceName} = {
        group = "Home";
        name = "Actual Budget";
        icon = "actual-budget";
        href = externalUrl;
        description = "Personal finance";
        siteMonitor = internalUrl;
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.${serviceName} = {
        name = "Actual Budget";
        group = "Home";
        url = externalUrl;
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 1000"
        ];
      };
    })
  ];
}
