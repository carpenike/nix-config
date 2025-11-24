# hosts/forge/services/qbittorrent.nix
#
# Host-specific configuration for the qBittorrent service on 'forge'.
# qBittorrent is the primary BitTorrent download client.

{ config, ... }:

{
  config = {
    modules.services.qbittorrent = {
      enable = true;

      # Pin container image to specific version with digest
      image = "ghcr.io/home-operations/qbittorrent:5.1.2@sha256:31ac39705e31f7cdcc04dc46c1c0b0cdf8dc6f9865d4894efc097a33adc41524";

      # BitTorrent port (migrated from k8s)
      torrentPort = 61144;

      # Downloads directory on NFS (category-based structure already exists)
      # /mnt/data/qb/downloads/{sonarr,radarr,lidarr,readarr,prowlarr}
      nfsMountDependency = "media";
      podmanNetwork = "media-services";
      healthcheck.enable = true;

      # Enable VueTorrent modern WebUI
      vuetorrent.enable = true;

      # Reverse proxy configuration for external access
      reverseProxy = {
        enable = true;
        hostName = "qbittorrent.holthome.net";

        # Protect via Pocket ID + caddy-security; grant media role based on claim
        caddySecurity = {
          enable = true;
          portal = "pocketid";
          policy = "media";
          claimRoles = [
            {
              claim = "groups";
              value = "media";
              role = "media";
            }
          ];
        };
      };

      # Enable backups (config only - downloads are NOT backed up)
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/qbittorrent";
      };

      # Enable failure notifications
      notifications.enable = true;

      # Enable self-healing restore
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ]; # Restic excluded: preserve ZFS lineage
      };
    };

      # ZFS snapshot and replication configuration for qBittorrent dataset
    # Contributes to host-level Sanoid configuration following the contribution pattern
    # NOTE: Downloads are NOT backed up (transient data on NFS)
    modules.backup.sanoid.datasets."tank/services/qbittorrent" = {
      useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
      recursive = false;
      autosnap = true;
      autoprune = true;
      replication = {
        targetHost = "nas-1.holthome.net";
        targetDataset = "backup/forge/zfs-recv/qbittorrent";
        sendOptions = "wp";  # Raw encrypted send with property preservation
        recvOptions = "u";   # Don't mount on receive
        hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
        # Consistent naming for Prometheus metrics
        targetName = "NFS";
        targetLocation = "nas-1";
      };
    };

    # Service-specific monitoring alerts
    # Contributes to host-level alerting configuration following the contribution pattern
    modules.alerting.rules."qbittorrent-service-down" = {
      type = "promql";
      alertname = "QbittorrentServiceDown";
      expr = ''
        container_service_active{service="qbittorrent"} == 0
      '';
      for = "2m";
      severity = "high";
      labels = { service = "qbittorrent"; category = "container"; };
      annotations = {
        summary = "qBittorrent service is down on {{ $labels.instance }}";
        description = "Torrent download client is not running. Check: systemctl status podman-qbittorrent.service";
        command = "systemctl status podman-qbittorrent.service && journalctl -u podman-qbittorrent.service --since '30m'";
      };
    };
  };
}
