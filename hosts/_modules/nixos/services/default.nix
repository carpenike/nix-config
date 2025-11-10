{
  ...
}:
{
  imports = [
    ./adguardhome
    ./attic.nix
    ./attic-admin.nix
    ./authelia                                # Authelia SSO authentication service
    ./backup                                  # Unified backup management system
    ./backup-integration.nix                  # Legacy auto-discovery for service backup configurations
    ./bazarr                                  # Bazarr subtitle manager
    ./bind
    ./blocky
    ./caddy
    ./cfdyndns
    ./chrony
    ./cloudflared
    ./coachiq
    ./dispatcharr
    ./dnsdist
    ./glances
    ./grafana                                 # Grafana monitoring dashboard
    ./haproxy
    ./lidarr                                  # Lidarr music collection manager
    ./loki                                    # Loki log aggregation server
    ./nginx
    ./gpu-metrics
    ./node-exporter
    ./observability                           # Unified observability stack (Loki + Promtail)
    ./onepassword-connect
    ./openssh
    ./omada
    ./podman
    ./pgweb                                   # Pgweb PostgreSQL database browser
    ./plex
    ./postgresql                              # PostgreSQL module (simplified single-instance)
    ./postgresql/databases.nix                # Database provisioning (systemd units)
    ./postgresql/storage-integration.nix      # ZFS dataset creation (one-way integration)
    # ./postgresql/backup-integration.nix     # REMOVED: PostgreSQL backups now handled by pgBackRest
    ./promtail                                # Promtail log shipping agent
    ./prowlarr                                # Prowlarr indexer manager
    ./qbittorrent                             # qBittorrent torrent download client
    ./radarr                                  # Radarr movie collection manager
    ./readarr                                 # Readarr book/audiobook collection manager
    ./sabnzbd                                 # SABnzbd usenet download client
    ./sonarr
    ./unifi
    ./uptime-kuma                             # Uptime Kuma monitoring service (native wrapper)
    # ./ups                                   # REMOVED: Use services.nut directly in host configs
  ];
}
