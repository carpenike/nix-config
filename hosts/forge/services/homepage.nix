# hosts/forge/services/homepage.nix
#
# Host-specific configuration for Homepage dashboard on 'forge'.
# Homepage is a modern, customizable dashboard for homelab services.
#
# ARCHITECTURE:
# - Uses native NixOS service (services.homepage-dashboard)
# - Wrapped with homelab patterns: ZFS, backup, monitoring
# - Contributory pattern: other services can register themselves via
#   modules.services.homepage.contributions.<serviceName>
#
# ACCESS:
# - LAN only (no Cloudflare Tunnel - not public-facing)
# - Protected by PocketID authentication via Caddy
# - Domain: start.holthome.net

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.homepage.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.homepage = {
        enable = true;

        # Reverse proxy integration via Caddy with PocketID auth
        reverseProxy = {
          enable = true;
          hostName = "start.holthome.net";
          # Using home security level for PocketID authentication
          caddySecurity = forgeDefaults.caddySecurity.home;
        };

        # Backup using forgeDefaults helper with custom tags
        backup = forgeDefaults.mkBackupWithTags "homepage" (forgeDefaults.backupTags.infrastructure ++ [ "homepage" "dashboard" "forge" ]);

        # Enable widgets for system information (list of widget configs)
        widgets = [
          # Search widget at the top
          {
            search = {
              provider = "duckduckgo";
              focus = true;
              target = "_blank";
            };
          }
          # System resources
          {
            resources = {
              cpu = true;
              memory = true;
              disk = "/";
              cputemp = true;
              uptime = true;
            };
          }
          # Date/time display
          {
            datetime = {
              text_size = "xl";
              format = {
                dateStyle = "long";
                timeStyle = "short";
                hour12 = false;
              };
            };
          }
        ];

        # Settings for the dashboard
        settings = {
          title = "Homelab";
          favicon = "https://start.holthome.net/favicon.ico";
          theme = "dark";
          color = "slate";
          headerStyle = "boxed";

          # Background image with opacity/blur for readability
          background = {
            image = "https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&w=2560&q=80";
            blur = "sm";
            saturate = 50;
            brightness = 50;
            opacity = 50;
          };

          layout = {
            Media = {
              style = "row";
              columns = 4;
            };
            Downloads = {
              style = "row";
              columns = 3;
            };
            Monitoring = {
              style = "row";
              columns = 3;
            };
            Infrastructure = {
              style = "row";
              columns = 4;
            };
            Home = {
              style = "row";
              columns = 3;
            };
          };
        };
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/homepage" =
        forgeDefaults.mkSanoidDataset "homepage";

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."homepage-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "homepage-dashboard" "Homepage" "dashboard";

      # Widget API key secrets via SOPS template
      # The template re-uses existing arr service secrets (sonarr/api-key, radarr/api-key, etc.)
      # and exposes them as HOMEPAGE_VAR_* environment variables
      modules.services.homepage.environmentFile = config.sops.templates."homepage-env".path;

      # NOTE: No Cloudflare Tunnel - this is LAN only (not public-facing)
      # Access via start.holthome.net requires VPN or local network
    })
  ];
}
