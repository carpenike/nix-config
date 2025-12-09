# hosts/forge/services/thelounge.nix
#
# Host-specific configuration for TheLounge IRC client on 'forge'.
# This module consumes the reusable abstraction defined in:
# hosts/_modules/nixos/services/thelounge/default.nix
#
# TheLounge provides a persistent IRC bouncer with web interface.
# Access is controlled via PocketID (admin group only).
# Internal only - no Cloudflare Tunnel.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.thelounge.enable or false;

  # Service configuration values - single source of truth
  # Port 9087: Next available after cooklang-federation (9086)
  # Avoiding 9000 which is mealie's internal container port
  serviceName = "thelounge";
  port = 9087;
  hostName = "irc.${config.networking.domain}";
  externalUrl = "https://${hostName}";
  internalUrl = "http://127.0.0.1:${toString port}";
in
{
  config = lib.mkMerge [
    {
      modules.services.thelounge = {
        enable = true;

        # Override default port to avoid conflicts (mealie uses 9000 internally)
        port = port;

        # Disable native authentication (use caddySecurity instead)
        public = true;

        # Default IRC network - Libera.Chat (successor to Freenode)
        defaultNetwork = {
          name = "Libera.Chat";
          host = "irc.libera.chat";
          port = 6697;
          tls = true;
          nick = "holthome";
          join = "#nixos,#home-assistant";
          lockNetwork = false; # Allow adding other networks
        };

        # Reverse proxy configuration for external access via Caddy
        reverseProxy = {
          enable = true;
          hostName = hostName;
          backend = {
            host = "127.0.0.1";
            port = port;
          };
          # Admin-only access via PocketID
          caddySecurity = forgeDefaults.caddySecurity.admin;
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
      # ZFS dataset for TheLounge data
      # Must set owner/group/mode explicitly - StateDirectory can't change
      # permissions on pre-existing ZFS mountpoints
      modules.storage.datasets.services.thelounge = {
        mountpoint = "/var/lib/thelounge";
        recordsize = "128K"; # Mixed file sizes (user configs, logs, message history)
        compression = "lz4";
        owner = config.modules.services.thelounge.user;
        group = config.modules.services.thelounge.group;
        mode = "0750";
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/${serviceName}" =
        forgeDefaults.mkSanoidDataset serviceName;

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert serviceName "TheLounge" "IRC web client";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.${serviceName} = {
        group = "Services";
        name = "TheLounge";
        icon = "thelounge";
        href = externalUrl;
        description = "IRC web client";
        siteMonitor = internalUrl;
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.${serviceName} = {
        name = "TheLounge";
        group = "Services";
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
