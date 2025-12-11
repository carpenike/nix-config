{ ...
}:
{
  imports = [
    ./actual # Actual Budget personal finance app (native wrapper)
    ./adguardhome
    ./attic.nix
    ./attic-admin.nix
    ./attic-push.nix
    ./autobrr # Autobrr IRC announce bot for torrents
    ./backup # Unified backup management system
    ./bichon # Bichon email archiving system
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
    ./github-runner # GitHub Actions self-hosted runner
    ./dnsdist
    ./glances
    ./grafana # Grafana monitoring dashboard
    ./grafana-oncall # Grafana OnCall incident response platform
    ./haproxy
    ./home-assistant
    ./homepage # Homepage dashboard (native wrapper)
    ./it-tools # IT-Tools developer utilities
    ./zigbee2mqtt
    ./zwave-js-ui
    ./lidarr # Lidarr music collection manager
    ./litellm # LiteLLM unified AI gateway (native wrapper)
    ./loki # Loki log aggregation server
    ./mealie # Mealie recipe manager
    ./miniflux # Miniflux minimalist RSS reader
    ./n8n # n8n workflow automation
    ./nginx
    ./gpu-metrics
    ./node-exporter
    ./observability # Unified observability stack (Loki + Promtail)
    ./onepassword-connect
    ./open-webui # Open WebUI AI chat interface
    ./openssh
    ./omada
    ./paperless # Paperless-ngx document management system
    ./paperless-ai # Paperless-AI document tagging service
    ./pinchflat # Pinchflat YouTube media manager (native wrapper)
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
    ./kometa # Kometa Plex metadata manager (formerly Plex Meta Manager)
    ./sabnzbd # SABnzbd usenet download client
    ./scrypted # Scrypted NVR / automation hub
    ./searxng # SearXNG meta search engine
    ./sonarr
    ./teslamate # TeslaMate telemetry stack
    ./tautulli # Tautulli Plex monitoring (native wrapper)
    ./tdarr # Tdarr transcoding automation
    ./thelounge # TheLounge IRC web client (native wrapper)
    ./tqm # tqm fast torrent management for racing
    ./unifi
    ./unpackerr # Unpackerr archive extraction for Starr apps
    # ./ups                                   # REMOVED: Use services.nut directly in host configs
  ];
}
