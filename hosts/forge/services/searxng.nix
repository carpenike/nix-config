# hosts/forge/services/searxng.nix
#
# Host-specific configuration for SearXNG on 'forge'.
# SearXNG is a privacy-respecting meta search engine.
#
# Features:
# - Redis rate limiter for bot protection
# - JSON format enabled for Open-WebUI RAG integration
# - Local access only (no Cloudflare Tunnel)
# - ZFS dataset for configuration persistence
#
# Access: https://search.holthome.net (VPN only)

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "search.${domain}";
  dataset = "tank/services/searxng";
  dataDir = "/var/lib/searxng";
  listenPort = 8888;
  serviceEnabled = config.modules.services.searxng.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.searxng = {
        enable = true;
        port = listenPort;
        dataDir = dataDir;

        # Enable Redis for rate limiting and bot protection
        redisCreateLocally = true;

        # Secret key for secure sessions
        secretKeyFile = config.sops.secrets."searxng/secret-key".path;

        # Reverse proxy configuration (no auth - local access only)
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = listenPort;
          };
        };

        # Backup configuration
        backup = forgeDefaults.backup;

        # Enable self-healing restore from backups before service start
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    # Infrastructure contributions - guarded by service enable
    (lib.mkIf serviceEnabled {
      # ZFS dataset for SearXNG data
      modules.storage.datasets.services."searxng" = {
        mountpoint = dataDir;
        recordsize = "16K"; # Small files (config, settings)
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        owner = "searx";
        group = "searx";
        mode = "0750";
      };

      # Sanoid snapshot/replication to NAS
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "searxng";

      # Service-down alert (native systemd service)
      modules.alerting.rules."searxng-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "searx" "SearXNG" "meta search engine";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.searxng = {
        group = "Tools";
        name = "SearXNG";
        icon = "searxng";
        href = "https://${serviceDomain}";
        description = "Privacy-respecting meta search";
        siteMonitor = "http://127.0.0.1:${toString listenPort}";
      };

      # Gatus health check contribution
      modules.services.gatus.contributions.searxng = {
        name = "SearXNG";
        group = "Tools";
        url = "http://127.0.0.1:${toString listenPort}/healthz";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
        ];
      };
    })
  ];
}
