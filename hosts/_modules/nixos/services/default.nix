{ ...
}:
{
  imports = [
    ./adguardhome
    ./attic.nix
    ./attic-admin.nix
    ./attic-push.nix
    ./autobrr # Autobrr IRC announce bot for torrents
    ./backup # Unified backup management system
    ./backup-integration.nix # Legacy auto-discovery for service backup configurations
    ./bazarr # Bazarr subtitle manager
    ./bind
    ./blocky
    ./caddy
    ./cfdyndns
    ./chrony
    ./cloudflared
    ./coachiq
    ./cooklang # Cooklang recipe management server
    ./cooklang-federation # Cooklang Federation discovery service
    ./cross-seed # cross-seed automatic cross-seeding daemon
    ./dispatcharr
    ./esphome # ESPHome dashboard and firmware builder
    ./emqx # EMQX MQTT broker service
    ./enclosed # Enclosed encrypted note sharing service
    ./frigate # Frigate NVR wrapper
    ./gatus # Gatus black-box monitoring (replaces Uptime Kuma)
    ./dnsdist
    ./glances
    ./grafana # Grafana monitoring dashboard
    ./haproxy
    ./home-assistant
    ./homepage # Homepage dashboard (native wrapper)
    ./zigbee2mqtt
    ./zwave-js-ui
    ./lidarr # Lidarr music collection manager
    ./litellm # LiteLLM unified AI gateway (native wrapper)
    ./loki # Loki log aggregation server
    ./mealie # Mealie recipe manager
    ./nginx
    ./gpu-metrics
    ./node-exporter
    ./observability # Unified observability stack (Loki + Promtail)
    ./onepassword-connect
    ./open-webui # Open WebUI AI chat interface
    ./openssh
    ./omada
    ./paperless # Paperless-ngx document management system
    ./seerr # Seerr request management (successor to Overseerr/Jellyseerr)
    ./podman
    ./pgweb # Pgweb PostgreSQL database browser
    ./plex
    ./pocketid # Pocket ID authentication portal
    ./postgresql # PostgreSQL module (simplified single-instance)
    ./postgresql/databases.nix # Database provisioning (systemd units)
    ./postgresql/storage-integration.nix # ZFS dataset creation (one-way integration)
    # ./postgresql/backup-integration.nix     # REMOVED: PostgreSQL backups now handled by pgBackRest
    ./profilarr # Profilarr quality profile sync
    ./promtail # Promtail log shipping agent
    ./prowlarr # Prowlarr indexer manager
    ./qbittorrent # qBittorrent torrent download client
    ./qbit-manage # qbit_manage torrent lifecycle management
    ./resilio-sync # Resilio Sync helper for declarative shared folders
    ./qui # qui modern qBittorrent web interface
    ./radarr # Radarr movie collection manager
    ./readarr # Readarr book/audiobook collection manager
    ./recyclarr # Recyclarr TRaSH Guides automation
    ./sabnzbd # SABnzbd usenet download client
    ./scrypted # Scrypted NVR / automation hub
    ./sonarr
    ./teslamate # TeslaMate telemetry stack
    ./tautulli # Tautulli Plex monitoring (native wrapper)
    ./tdarr # Tdarr transcoding automation
    ./tqm # tqm fast torrent management for racing
    ./unifi
    # ./ups                                   # REMOVED: Use services.nut directly in host configs
  ];
}
