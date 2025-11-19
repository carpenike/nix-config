{ lib, ... }:

let
  # Centralized Cloudflare R2 configuration for offsite backups
  # Used by: pgBackRest (PostgreSQL), Restic (system backups)
  r2Config = {
    endpoint = "21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com";
    bucket = "nix-homelab-prod-servers";
  };
in

{
  imports = [
    # Common modules
    ../_modules/common/r2-config.nix

    # Hardware & Disk Configuration
    (import ./disko-config.nix {
      disks = [ "/dev/disk/by-id/nvme-Samsung_SSD_950_PRO_512GB_S2GMNX0H803986M" "/dev/disk/by-id/nvme-WDS100T3X0C-00SJG0_200278801343" ];
      inherit lib;  # Pass lib here
    })
    ../../profiles/hardware/intel-gpu.nix

    # Core System Configuration
    ./core/networking.nix
    ./core/boot.nix
    ./core/users.nix
    ./core/packages.nix
    ./core/hardware.nix
    ./core/monitoring.nix           # Core system health monitoring (CPU, memory, disk, systemd)
    ./core/system-services.nix      # System service configurations (rsyslog, journald)

    # Infrastructure (Cross-cutting operational concerns)
    ./infrastructure/backup.nix
    ./infrastructure/containerization.nix  # Podman container networking
    ./infrastructure/notifications.nix     # Notification system (Pushover, system events)
    ./infrastructure/storage.nix      # ZFS storage management and Sanoid templates
    ./infrastructure/reverse-proxy.nix  # Caddy reverse proxy configuration
    ./infrastructure/monitoring-ui.nix
    ./infrastructure/observability  # Prometheus, Alertmanager, Grafana, Loki, Promtail

    # Secrets
    ./secrets.nix

    # Application Services
    ./services/postgresql.nix      # PostgreSQL database
    ./services/pgbackrest.nix      # pgBackRest PostgreSQL backup system
    ./services/dispatcharr.nix     # Dispatcharr service
    ./services/plex.nix            # Plex media server
    ./services/uptime-kuma.nix     # Uptime monitoring and status page
    ./services/ups.nix             # UPS monitoring configuration
    ./services/pgweb.nix           # PostgreSQL web management interface
    ./services/authelia.nix        # SSO authentication service
    ./services/qui.nix             # qui - Modern qBittorrent web interface with OIDC
    ./services/cloudflare-tunnel.nix  # Cloudflare Tunnel for external access
    ./services/sonarr.nix          # Sonarr TV series management
    ./services/prowlarr.nix        # Prowlarr indexer manager
    ./services/radarr.nix          # Radarr movie manager
    ./services/bazarr.nix          # Bazarr subtitle manager
    ./services/recyclarr.nix       # Recyclarr TRaSH guides automation
    ./services/qbittorrent.nix     # qBittorrent download client
    ./services/cross-seed.nix      # cross-seed torrent automation
    ./services/tqm.nix             # tqm torrent lifecycle management
    ./services/qbit-manage.nix     # qbit-manage (DISABLED - migrated to tqm)
    ./services/sabnzbd.nix         # SABnzbd usenet downloader
    ./services/overseerr.nix       # Overseerr media request management
    ./services/autobrr.nix         # Autobrr IRC announce bot
    ./services/profilarr.nix       # Profilarr profile sync for *arr services
    ./services/tdarr.nix           # Tdarr transcoding automation
    ./services/cooklang.nix        # Cooklang recipe management
    ./services/cooklang-federation.nix  # Cooklang federation search service
    ./services/emqx.nix            # Shared EMQX MQTT broker
    ./services/teslamate.nix       # TeslaMate telemetry + dashboards
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.30";

    # Centralized R2 configuration accessible to all services
    my.r2 = r2Config;

    modules = {
      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" "tank" ];
        # Use default rpool/safe/persist for system-level /persist
      };

      # Enable Intel DRI / VA-API support on this host
      common.intelDri = {
        enable = true;
        driver = "iHD"; # Use iHD (intel-media-driver) for modern Intel GPUs; set to "i965" for legacy hardware
        services = [ "podman-dispatcharr.service" ];
      };

      # (moved) VA-API driver exposure configured via top-level 'hardware.opengl'

      # Alert monitoring rules now defined in infrastructure/alerts.nix
      # Storage dataset management now configured in infrastructure/storage.nix
      # Podman containerization now configured in infrastructure/containerization.nix
      # Notification system now configured in infrastructure/notifications.nix

      system.impermanence.enable = true;

      services = {
        openssh.enable = true;

        # Caddy reverse proxy
        caddy = {
          enable = true;
          # Domain defaults to networking.domain (holthome.net)
        };

      # Media management services
      # Sonarr configuration moved to ./services/sonarr.nix
      # Prowlarr configuration moved to ./services/prowlarr.nix
      # Radarr configuration moved to ./services/radarr.nix
      # Bazarr configuration moved to ./services/bazarr.nix
      # Recyclarr configuration moved to ./services/recyclarr.nix

      # Download clients and torrent tools
      # qBittorrent configuration moved to ./services/qbittorrent.nix
      # cross-seed configuration moved to ./services/cross-seed.nix
      # tqm configuration moved to ./services/tqm.nix
      # qbit-manage configuration moved to ./services/qbit-manage.nix
      # SABnzbd configuration moved to ./services/sabnzbd.nix
      # Overseerr configuration moved to ./services/overseerr.nix
      # Autobrr configuration moved to ./services/autobrr.nix
      # Profilarr configuration moved to ./services/profilarr.nix
      # Tdarr configuration moved to ./services/tdarr.nix

      # (rsyslogd configured at top-level services.rsyslogd)

      # Additional service-specific configurations are in their own files
      # See: dispatcharr.nix, etc.
        # Example service configurations can be copied from luna when ready
      };

      users = {
        groups = {
          admins = {
            gid = 991;
            members = [
              "ryan"
            ];
          };
          # media group now defined at top level with GID 65537 for *arr services
        };
      };
    };

    # System service configurations (rsyslog, caddy, journald) moved to ./core/system-services.nix

    system.stateVersion = "25.05";  # Set to the version being installed (new system, never had 23.11)
  };
}
