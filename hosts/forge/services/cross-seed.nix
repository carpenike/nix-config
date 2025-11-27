# hosts/forge/services/cross-seed.nix
#
# Host-specific configuration for the cross-seed service on 'forge'.
# cross-seed automates finding cross-seeds across multiple torrent trackers.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.cross-seed.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.cross-seed = {
        enable = true;

        # Pure API mode: inject torrents directly via qBittorrent API
        # No NFS mount needed - all operations via API
        podmanNetwork = forgeDefaults.podmanNetwork;
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
            "http://prowlarr:9696/1/api?apikey={{PROWLARR_API_KEY}}" # Anthelion
            "http://prowlarr:9696/2/api?apikey={{PROWLARR_API_KEY}}" # Blutopia
            "http://prowlarr:9696/3/api?apikey={{PROWLARR_API_KEY}}" # BroadcasTheNet
            "http://prowlarr:9696/6/api?apikey={{PROWLARR_API_KEY}}" # FileList.io
            "http://prowlarr:9696/8/api?apikey={{PROWLARR_API_KEY}}" # MoreThanTV
            "http://prowlarr:9696/9/api?apikey={{PROWLARR_API_KEY}}" # MyAnonamouse
            "http://prowlarr:9696/13/api?apikey={{PROWLARR_API_KEY}}" # SceneTime
            "http://prowlarr:9696/14/api?apikey={{PROWLARR_API_KEY}}" # TorrentLeech
          ];

          # Sonarr/Radarr API integration
          sonarr = [ "http://sonarr:8989?apikey={{SONARR_API_KEY}}" ];
          radarr = [ "http://radarr:7878?apikey={{RADARR_API_KEY}}" ];

          # Pure API mode: inject torrents directly via qBittorrent API
          # No filesystem paths needed - cross-seed uses API for everything
          dataDirs = [ ];
          linkDirs = [ ];

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
          # No external auth: cross-seed’s daemon API already enforces an API key.
        };

        # Enable metrics
        metrics.enable = true;

        # Enable backups
        backup = forgeDefaults.mkBackupWithSnapshots "cross-seed";

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
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/cross-seed" = forgeDefaults.mkSanoidDataset "cross-seed";

      # Service availability alert
      modules.alerting.rules."cross-seed-service-down" =
        forgeDefaults.mkServiceDownAlert "cross-seed" "CrossSeed" "cross-seeding automation";
    })
  ];
}
