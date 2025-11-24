# hosts/forge/services/cross-seed.nix
#
# Host-specific configuration for the cross-seed service on 'forge'.
# cross-seed automates finding cross-seeds across multiple torrent trackers.

{ config, lib, ... }:

let
  serviceEnabled = config.modules.services.cross-seed.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.cross-seed = {
        enable = true;

      # Pure API mode: inject torrents directly via qBittorrent API
      # No NFS mount needed - all operations via API
      podmanNetwork = "media-services";
      healthcheck.enable = true;

      # API key files for service integrations
      apiKeyFile = config.sops.secrets."cross-seed/api-key".path;
      prowlarrApiKeyFile = config.sops.secrets."prowlarr/api-key".path;
      sonarrApiKeyFile = config.sops.secrets."sonarr/api-key".path;
      radarrApiKeyFile = config.sops.secrets."radarr/api-key".path;

      # Configuration settings for cross-seed daemon
      extraSettings = {
        delay = 30; # Minimum allowed by cross-seed v6

        # Torznab indexers from Prowlarr (v6 simplified format)
        # Placeholders get substituted at runtime by cross-seed-config.service
        torznab = [
          "http://prowlarr:9696/1/api?apikey={{PROWLARR_API_KEY}}"   # Anthelion
          "http://prowlarr:9696/2/api?apikey={{PROWLARR_API_KEY}}"   # Blutopia
          "http://prowlarr:9696/3/api?apikey={{PROWLARR_API_KEY}}"   # BroadcasTheNet
          "http://prowlarr:9696/6/api?apikey={{PROWLARR_API_KEY}}"   # FileList.io
          "http://prowlarr:9696/8/api?apikey={{PROWLARR_API_KEY}}"   # MoreThanTV
          "http://prowlarr:9696/9/api?apikey={{PROWLARR_API_KEY}}"   # MyAnonamouse
          "http://prowlarr:9696/13/api?apikey={{PROWLARR_API_KEY}}"  # SceneTime
          "http://prowlarr:9696/14/api?apikey={{PROWLARR_API_KEY}}"  # TorrentLeech
        ];

        # Sonarr/Radarr API integration
        sonarr = [ "http://sonarr:8989?apikey={{SONARR_API_KEY}}" ];
        radarr = [ "http://radarr:7878?apikey={{RADARR_API_KEY}}" ];

        # Pure API mode: inject torrents directly via qBittorrent API
        # No filesystem paths needed - cross-seed uses API for everything
        dataDirs = [];
        linkDirs = [];

        # Match mode - "safe" prevents false positives
        matchMode = "safe";

        # Output directory - null for action=inject (API mode)
        outputDir = null;

        # qBittorrent client configuration for inject mode
        torrentClients = [
          "qbittorrent:http://qbittorrent:8080"
        ];
      };

      # Reverse proxy configuration for external access
      reverseProxy = {
        enable = true;
        hostName = "cross-seed.holthome.net";

        # Enable Authelia SSO protection
        authelia = {
          enable = true;
          instance = "main";
          authDomain = "auth.holthome.net";
          policy = "one_factor";
          allowedGroups = [ "media" "admin" ];
        };
      };

      # Enable metrics
      metrics.enable = true;

      # Enable backups
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/cross-seed";
      };

      # Enable failure notifications with custom message
      notifications = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "cross-seed automatic cross-seeding failed on forge";
        };
      };

      # Enable self-healing restore
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ];
      };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for cross-seed dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      # Stores cache database and generated torrent files
      modules.backup.sanoid.datasets."tank/services/cross-seed" = {
        useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/cross-seed";
          sendOptions = "wp";  # Raw encrypted send with property preservation
          recvOptions = "u";   # Don't mount on receive
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # Co-located Service Monitoring
      modules.alerting.rules."cross-seed-service-down" = {
        type = "promql";
        alertname = "CrossSeedServiceInactive";
        expr = "container_service_active{name=\"cross-seed\"} == 0";
        for = "2m";
        severity = "high";
        labels = { service = "cross-seed"; category = "availability"; };
        annotations = {
          summary = "cross-seed service is down on {{ $labels.instance }}";
          description = "The cross-seed automation service is not active.";
          command = "systemctl status podman-cross-seed.service";
        };
      };
    })
  ];
}
