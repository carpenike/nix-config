# hosts/forge/services/netvisor.nix
#
# Host-specific configuration for NetVisor on 'forge'.
# NetVisor is a network discovery and visualization tool that automatically
# scans your network, identifies hosts/services, and generates topology diagrams.
#
# Networks to scan: 10.20.0.0/16, 10.30.0.0/16, 10.50.0.0/16
# These are configured via the NetVisor UI after initial setup.
#
# Consumes the reusable module: modules/nixos/services/netvisor/default.nix

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.netvisor.enable or false;
  serviceDomain = "netvisor.${config.networking.domain}";
in
{
  config = lib.mkMerge [
    {
      # SOPS secrets for NetVisor
      # db_password needs group=postgres so postgresql-provision-databases can read it
      sops.secrets."netvisor/db_password" = {
        sopsFile = ../secrets.sops.yaml;
        owner = "netvisor";
        group = "postgres";
        mode = "0440";
      };

      sops.secrets."netvisor/oidc_client_secret" = {
        sopsFile = ../secrets.sops.yaml;
        owner = "netvisor";
        group = "netvisor";
        mode = "0400";
      };

      modules.services.netvisor = {
        enable = true;

        # Server configuration
        server = {
          publicUrl = "https://${serviceDomain}";
          disableRegistration = true; # Disable after initial account creation
          useSecureCookies = true; # Behind Caddy with TLS
          logLevel = "warn"; # Default; use "debug" or "trace" for troubleshooting
        };

        # Daemon configuration
        daemon = {
          name = "forge-daemon";
          # Explicit URL to override auto-detection (forge has many veth interfaces with 169.254.x.x)
          url = "http://10.20.0.30:60073";
          # Networks to scan (configured via UI, documented here for reference):
          # - 10.20.0.0/16 (main network)
          # - 10.30.0.0/16 (IoT network)
          # - 10.50.0.0/16 (services network)
          scanSubnets = [
            "10.20.0.0/16"
            "10.30.0.0/16"
            "10.50.0.0/16"
          ];
        };

        # Database configuration
        database = {
          passwordFile = config.sops.secrets."netvisor/db_password".path;
          manageDatabase = true;
        };

        # OIDC via PocketID
        oidc = {
          enable = true;
          providerName = "Holthome SSO";
          providerSlug = "pocketid";
          issuerUrl = "https://id.${config.networking.domain}";
          clientId = "netvisor";
          clientSecretFile = config.sops.secrets."netvisor/oidc_client_secret".path;
        };

        # Reverse proxy via Caddy (no caddySecurity - using native OIDC instead)
        # Native OIDC is preferred here because NetVisor supports it natively
        # and provides user-level features like audit trails and permissions
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
        };

        # Healthcheck for container monitoring
        healthcheck.enable = true;

        # Backup configuration
        backup = forgeDefaults.backup;

        # Notification on service failure
        notifications.enable = true;

        # Preseed for disaster recovery
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/netvisor" =
        forgeDefaults.mkSanoidDataset "netvisor";

      # Service-down alerts for both server and daemon
      modules.alerting.rules."netvisor-server-down" =
        forgeDefaults.mkServiceDownAlert "netvisor-server" "NetVisor Server" "network discovery server";

      modules.alerting.rules."netvisor-daemon-down" =
        forgeDefaults.mkServiceDownAlert "netvisor-daemon" "NetVisor Daemon" "network scanning daemon";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.netvisor = {
        group = "Infrastructure";
        name = "NetVisor";
        icon = "netvisor"; # Or use a generic network icon
        href = "https://${serviceDomain}";
        description = "Network discovery & topology visualization";
        siteMonitor = "http://localhost:60072/api/health";
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.netvisor = {
        name = "NetVisor";
        group = "Infrastructure";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 3000"
        ];
      };

      # Cloudflare tunnel for external access (optional - uncomment if needed)
      # modules.services.caddy.virtualHosts.netvisor.cloudflare = {
      #   enable = true;
      #   tunnel = "forge";
      # };
    })
  ];
}
