# hosts/forge/services/autobrr.nix
#
# Host-specific configuration for Autobrr on 'forge'.
# Autobrr is an IRC announce bot for torrent automation.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.autobrr.enable or false;
  inherit (config.networking) domain;
in
{
  config = lib.mkMerge [
    {
      modules.services.autobrr = {
        enable = true;
        # Canonical image pin (Renovate manages host-level pins; module default is an unpinned fallback)
        image = "ghcr.io/autobrr/autobrr:v1.81.0@sha256:491e3e1a81fe5ced6b542621e49985d0dea58d23257684b0b19d881761736303";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Hairpin-NAT workaround: id.holthome.net resolves to forge's LAN IP
        # (10.20.0.30), but autobrr's podman bridge can't reach the LAN — so
        # OIDC discovery (https://id.holthome.net/.well-known/openid-configuration)
        # times out from inside the container. Override the hosts file to point
        # at the podman bridge IP where Caddy also listens. Same pattern as qui.
        extraHosts = forgeDefaults.pocketidHostsEntry;

        settings = {
          host = "0.0.0.0"; # In-container bind - required for port mapping to work.
          # Host-side publish stays on the module default (127.0.0.1);
          # external access goes through Caddy (https://autobrr.holthome.net).
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

        # Prometheus metrics (in-container bind; published on 127.0.0.1 host-side)
        metrics = {
          enable = true;
          host = "0.0.0.0";
          port = 9084; # qui uses 9074, so use 9084 for autobrr
        };

        # Config generator with SOPS secrets injection
        configGenerator.environmentFile = config.sops.templates."autobrr-env".path;

        reverseProxy = {
          enable = true;
          hostName = "autobrr.${domain}";
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
        href = "https://autobrr.${domain}";
        description = "IRC announce bot";
        siteMonitor = "http://localhost:${toString config.modules.services.autobrr.port}";
        widget = {
          type = "autobrr";
          url = "http://localhost:${toString config.modules.services.autobrr.port}";
          key = "{{HOMEPAGE_VAR_AUTOBRR_API_KEY}}";
        };
      };
    })
  ];
}
