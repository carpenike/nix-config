# hosts/forge/services/qbittorrent.nix
#
# Host-specific configuration for the qBittorrent service on 'forge'.
# qBittorrent is the primary BitTorrent download client.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.qbittorrent.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.qbittorrent = {
        enable = true;

        # Pin container image to specific version with digest
        image = "ghcr.io/home-operations/qbittorrent:5.1.4@sha256:25fc7caf22101f85276ede9b1f76a46b7a93971bb6b70b6c58d14d6ab7f51415";

        # BitTorrent port (migrated from k8s)
        torrentPort = 61144;

        # Downloads directory on NFS (category-based structure already exists)
        # /mnt/data/qb/downloads/{sonarr,radarr,lidarr,readarr,prowlarr}
        nfsMountDependency = "media";
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Resource limits - qBittorrent with many torrents needs more memory
        resources = {
          memory = "4G";
          memoryReservation = "2G";
          cpus = "4.0";
        };

        # Enable VueTorrent modern WebUI
        vuetorrent.enable = true;

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "qbittorrent.holthome.net";
          caddySecurity = forgeDefaults.caddySecurity.media;
        };

        # Enable backups (config only - downloads are NOT backed up)
        backup = forgeDefaults.mkBackupWithSnapshots "qbittorrent";

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore (restic excluded: preserve ZFS lineage)
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/qbittorrent" = forgeDefaults.mkSanoidDataset "qbittorrent";

      # Service availability alert
      modules.alerting.rules."qbittorrent-service-down" =
        forgeDefaults.mkServiceDownAlert "qbittorrent" "Qbittorrent" "torrent download client";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.qbittorrent = {
        group = "Downloads";
        name = "qBittorrent";
        icon = "qbittorrent";
        href = "https://qbittorrent.holthome.net";
        description = "Torrent Client";
        siteMonitor = "http://localhost:8080";
        widget = {
          type = "qbittorrent";
          url = "http://localhost:8080";
          # Auth disabled - Caddy handles authentication
        };
      };
    })
  ];
}
