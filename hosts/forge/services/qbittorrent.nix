# hosts/forge/services/qbittorrent.nix
#
# Host-specific configuration for the qBittorrent service on 'forge'.
# qBittorrent is the primary BitTorrent download client.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.qbittorrent.enable;
in
{
  config = lib.mkMerge [
    {
      modules.services.qbittorrent = {
      enable = true;

      # Pin container image to specific version with digest
      image = "ghcr.io/home-operations/qbittorrent:5.1.2@sha256:31ac39705e31f7cdcc04dc46c1c0b0cdf8dc6f9865d4894efc097a33adc41524";

      # BitTorrent port (migrated from k8s)
      torrentPort = 61144;

      # Downloads directory on NFS (category-based structure already exists)
      # /mnt/data/qb/downloads/{sonarr,radarr,lidarr,readarr,prowlarr}
      nfsMountDependency = "media";
      podmanNetwork = forgeDefaults.podmanNetwork;
      healthcheck.enable = true;

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

      # ZFS snapshot and replication configuration for qBittorrent dataset
    # Contributes to host-level Sanoid configuration following the contribution pattern
    # NOTE: Downloads are NOT backed up (transient data on NFS)
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/qbittorrent" = forgeDefaults.mkSanoidDataset "qbittorrent";

      # Service availability alert
      modules.alerting.rules."qbittorrent-service-down" =
        forgeDefaults.mkServiceDownAlert "qbittorrent" "Qbittorrent" "torrent download client";
    })
  ];
}
