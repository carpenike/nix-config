# hosts/forge/services/cross-seed.nix
#
# Host-specific configuration for the cross-seed service on 'forge'.
# cross-seed automates finding cross-seeds across multiple torrent trackers.

{ config, ... }:

{
  config.modules.services.cross-seed = {
    enable = true;

    # Hybrid mode: APIs for metadata, filesystem for hardlinking
    # nfsMountDependency required - cross-seed needs write access for hardlink creation
    nfsMountDependency = "media";
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

      # Hybrid mode: API for metadata, filesystem for hardlinking
      dataDirs = [];
      linkDirs = [ "/data/qb/downloads" ];

      # Match mode - "safe" prevents false positives
      matchMode = "safe";

      # Output directory - null for action=inject
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
