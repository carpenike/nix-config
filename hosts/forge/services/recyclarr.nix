# hosts/forge/services/recyclarr.nix
#
# Host-specific configuration for the Recyclarr service on 'forge'.
# Recyclarr automates TRaSH Guides configuration for Sonarr and Radarr.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.recyclarr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.recyclarr = {
        enable = true;

        # Pin container image to specific version
        image = "ghcr.io/recyclarr/recyclarr:7.5.2";

        # Sync TRaSH guides once per day at a random time
        schedule = "daily";

        # Attach to media services network for DNS resolution to Sonarr and Radarr
        podmanNetwork = forgeDefaults.podmanNetwork;

        # Sonarr configuration - WEB-1080p quality profile
        sonarr.sonarr-main = {
          baseUrl = "http://sonarr:8989";
          apiKeyFile = config.sops.secrets."sonarr/api-key".path;

          # Enable automatic cleanup of obsolete custom formats
          deleteOldCustomFormats = true;

          # Media naming configuration disabled - configure manually in Sonarr UI
          # The TRaSH guide formats need to be set directly in the UI, not via API
          # Recommended formats from TRaSH:
          # - Series Folder: {Series TitleYear} {tvdb-{TvdbId}}
          # - Season Folder: Season {season:00}
          # - Episode Format: {Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}

          templates = [
            "sonarr-quality-definition-series"
            "sonarr-v4-quality-profile-web-1080p"
            "sonarr-v4-custom-formats-web-1080p"
          ];
        };

        # Radarr configuration - HD Bluray + WEB quality profile
        radarr.radarr-main = {
          baseUrl = "http://radarr:7878";
          apiKeyFile = config.sops.secrets."radarr/api-key".path;

          # Enable automatic cleanup of obsolete custom formats
          deleteOldCustomFormats = true;

          # Media naming configuration disabled - configure manually in Radarr UI
          # The TRaSH guide formats need to be set directly in the UI, not via API
          # Recommended formats from TRaSH:
          # - Folder Names: {Movie CleanTitle} ({Release Year}) {tmdb-{TmdbId}}
          # - File Names: {Movie CleanTitle} {(Release Year)} {tmdb-{TmdbId}} - {edition-{Edition Tags}} {[MediaInfo 3D]}{[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}

          templates = [
            "radarr-quality-definition-movie"
            "radarr-quality-profile-hd-bluray-web"
            "radarr-custom-formats-hd-bluray-web"
          ];
        };

        # Enable backups
        backup = forgeDefaults.mkBackupWithSnapshots "recyclarr";

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/recyclarr" = forgeDefaults.mkSanoidDataset "recyclarr";

      # Service availability alert
      modules.alerting.rules."recyclarr-service-down" =
        forgeDefaults.mkServiceDownAlert "recyclarr" "Recyclarr" "TRaSH guide automation";
    })
  ];
}
