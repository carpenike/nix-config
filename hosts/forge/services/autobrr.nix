# hosts/forge/services/autobrr.nix
#
# Host-specific configuration for Autobrr on 'forge'.
# Autobrr is an IRC announce bot for torrent automation.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.autobrr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.autobrr = {
        enable = true;
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        settings = {
          host = "0.0.0.0";
          port = 7474;
          logLevel = "INFO";
          checkForUpdates = false; # Managed via Nix/Renovate
          sessionSecretFile = config.sops.secrets."autobrr/session-secret".path;
        };

        # Native PocketID OIDC integration
        oidc = {
          enable = true;
          issuer = "https://id.${config.networking.domain}";
          clientId = "autobrr";
          clientSecretFile = config.sops.secrets."autobrr/oidc-client-secret".path;
          redirectUrl = "https://autobrr.${config.networking.domain}/api/auth/oidc/callback";
          disableBuiltInLogin = false;
        };

        # Prometheus metrics
        metrics = {
          enable = true;
          host = "0.0.0.0";
          port = 9084; # qui uses 9074, so use 9084 for autobrr
        };

        # Config generator with SOPS secrets injection
        configGenerator.environmentFile = config.sops.templates."autobrr-env".path;

        reverseProxy = {
          enable = true;
          hostName = "autobrr.holthome.net";
        };

        backup = forgeDefaults.mkBackupWithSnapshots "autobrr";

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/autobrr" = forgeDefaults.mkSanoidDataset "autobrr";

      # Service availability alert
      modules.alerting.rules."autobrr-service-down" =
        forgeDefaults.mkServiceDownAlert "autobrr" "Autobrr" "IRC announce bot";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.autobrr = {
        group = "Downloads";
        name = "Autobrr";
        icon = "autobrr";
        href = "https://autobrr.holthome.net";
        description = "IRC announce bot";
        siteMonitor = "http://localhost:7474";
        widget = {
          type = "autobrr";
          url = "http://localhost:7474";
          key = "{{HOMEPAGE_VAR_AUTOBRR_API_KEY}}";
        };
      };
    })
  ];
}
