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

        # Radarr configuration - SQP-1 profiles for both 1080p and 4K
        # Uses Streaming Quality Profiles optimized for high-quality content
        # - SQP-1 (2160p): 4K content with Dolby Vision support
        # - SQP-1 (1080p): Standard HD content, Bluray + WEB sources
        #
        # After sync, assign movies to profiles in Radarr UI:
        # - "SQP-1 (2160p)" for 4K content
        # - "SQP-1 (1080p)" for 1080p content

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
            # Streaming-optimized quality definitions (file sizes)
            "radarr-quality-definition-sqp-streaming"

            # SQP-1 2160p (4K) profile - most stringent, top-tier groups
            # Using -default variant (standard DV/HDR support, no IMAX-E prioritization)
            "radarr-quality-profile-sqp-1-2160p-default"
            "radarr-custom-formats-sqp-1-2160p"

            # SQP-1 1080p profile - most stringent HD, Bluray + WEB sources
            "radarr-quality-profile-sqp-1-1080p"
            "radarr-custom-formats-sqp-1-1080p"
          ];

          # Optional: Prefer special movie versions (Remaster, Criterion, IMAX)
          # These custom formats add positive scores to preferred release versions
          customFormats = [
            {
              trash_ids = [
                # Movie Versions - uncomment to prefer these releases
                "570bc9ebecd92723d2d21500f4be314c" # Remaster
                "eca37840c13c6ef2dd0262b141a5482f" # 4K Remaster
                "e0c07d59beb37348e975a930d5e50319" # Criterion Collection
                "9d27d9d2181838f76dee150882bdc58c" # Masters of Cinema
                "db9b4c4b53d312a3ca5f1378f6440fc9" # Vinegar Syndrome
                "957d0f44b592285f26449575e8b1167e" # Special Edition
                "9f6cbff8cfe4ebbc1bde14c7b7bec0de" # IMAX Enhanced
              ];
              assign_scores_to = [
                { name = "SQP-1 (1080p)"; }
                { name = "SQP-1 (2160p)"; }
              ];
            }
          ];

          # Quality profile settings - uncomment min_format_score if you have limited indexers
          # qualityProfiles = [
          #   {
          #     name = "SQP-1 (1080p)";
          #     min_format_score = 10;  # Accept releases scoring ≥10
          #     reset_unmatched_scores = true;
          #   }
          #   {
          #     name = "SQP-1 (2160p)";
          #     min_format_score = 10;
          #     reset_unmatched_scores = true;
          #   }
          # ];
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
