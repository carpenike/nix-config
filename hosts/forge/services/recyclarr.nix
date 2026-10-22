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

        # recyclarr v8 note
        # -----------------
        # v8 removed every official `include: - template:` (the config-templates
        # repo moved to v8 on 2026-08-07, which broke the v7 nightly sync). The
        # old includes map 1:1 onto guide-backed quality profiles (`trash_id`),
        # which pull qualities, score set, custom formats and scores straight
        # from TRaSH Guides, plus `qualityDefinition` for file sizes.
        #
        # Profile adoption: each profile keeps `name` set to the profile's
        # *current* name in Sonarr/Radarr. With a matching name, recyclarr
        # (>= 8.4) adopts the existing profile on the first sync instead of
        # creating a duplicate, and keeps that name afterwards (dropping `name`
        # would rename it to the guide name, e.g. "[SQP] SQP-1 (2160p)").
        # https://recyclarr.dev/guide/upgrade-guide/v8.0/#adopting-guide-backed-quality-profiles
        #
        # trash_ids come from TRaSH-Guides docs/json/{sonarr,radarr}/quality-profiles/*.json
        # (also referenced by recyclarr/config-templates v8 templates).

        # Sonarr configuration - WEB-1080p and WEB-2160p quality profiles
        # Mirrors the Radarr dual-resolution setup:
        # - WEB-1080p: Standard HD content
        # - WEB-2160p: 4K content
        #
        # After sync, assign series to profiles in Sonarr UI:
        # - "WEB-1080p" for 1080p content
        # - "WEB-2160p" for 4K content
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

          # was: sonarr-quality-definition-series
          qualityDefinition = "series";

          qualityProfiles = [
            # was: sonarr-v4-quality-profile-web-1080p + sonarr-v4-custom-formats-web-1080p
            {
              trash_id = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
              name = "WEB-1080p";
            }
            # was: sonarr-v4-quality-profile-web-2160p + sonarr-v4-custom-formats-web-2160p
            {
              trash_id = "d1498e7d189fbe6c7110ceaabb7473e6"; # WEB-2160p
              name = "WEB-2160p";
            }
          ];

          customFormatGroups.add = [
            # Keep DSCP, which the v7 WEB-1080p/2160p includes scored but the
            # guide now ships only as an optional streaming service.
            {
              trash_id = "7832db22b71ab669458c17a2850d6913"; # [Streaming Services] Miscellaneous
              select = [
                "dc5f2bb0e0262155b5fedd0f6c5d2b55" # DSCP
              ];
            }
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

          # Streaming-optimized quality definitions (file sizes)
          # was: radarr-quality-definition-sqp-streaming
          qualityDefinition = "sqp-streaming";

          qualityProfiles = [
            # SQP-1 2160p (4K) profile - most stringent, top-tier groups
            # (standard DV/HDR support, no IMAX-E prioritization)
            # was: radarr-quality-profile-sqp-1-2160p-default + radarr-custom-formats-sqp-1-2160p
            {
              trash_id = "5128baeb2b081b72126bc8482b2a86a0"; # [SQP] SQP-1 (2160p)
              name = "SQP-1 (2160p)";
            }
            # SQP-1 1080p profile - most stringent HD, Bluray + WEB sources
            # was: radarr-quality-profile-sqp-1-1080p + radarr-custom-formats-sqp-1-1080p
            {
              trash_id = "0896c29d74de619df168d23b98104b22"; # [SQP] SQP-1 (1080p)
              name = "SQP-1 (1080p)";
            }
          ];

          customFormatGroups.add = [
            # Keep 10bit blocked (-10000 in the SQP-1 score sets), as the v7 SQP-1
            # includes did. The guide now lists it as optional in this group.
            {
              trash_id = "15b1cf0b6f1a1493856a4355907affee"; # [Unwanted] Unwanted Formats SQP
              select = [
                "a5d148168c4506b55cf53984107c396e" # 10bit
              ];
            }
          ];

          # Prefer special movie versions (Remaster, Criterion, IMAX)
          # These custom formats add positive scores to preferred release versions
          customFormats = [
            {
              trash_ids = [
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

          # To override guide values (e.g. with limited indexers), add attributes
          # to the qualityProfiles entries above, e.g. `min_format_score = 10;`.
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
      modules.storage.datasets.services.recyclarr.protection = {
        class = "ephemeral";
        objectives = {
          onsiteRpoSeconds = null;
          offsiteRpoSeconds = null;
          rtoSeconds = null;
        };
        requiredTiers = [ ];
        consistency = "crash-consistent";
        validator = null;
        allowEmptyBootstrap = true;
        mechanism = {
          name = "none";
          reason = "Configuration is declared in Nix and cached TRaSH repositories are fetched from upstream.";
        };
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/recyclarr" = forgeDefaults.mkSanoidDataset "recyclarr";

      # No service-down alert here on purpose.
      #
      # Recyclarr is not a long-running container -- it runs as the oneshot
      # recyclarr-sync.service driven by recyclarr-sync.timer, and there is no
      # podman-recyclarr.service. The previous mkServiceDownAlert call queried
      # container_service_active{name="recyclarr"}, a series the textfile
      # collector never emits (it only enumerates live podman-* units), so the
      # rule could not fire under any circumstance while making the service
      # look monitored.
      #
      # Its real failure modes are already covered generically:
      #   systemd-unit-failed  node_systemd_unit_state{state="failed"} == 1
      #                        catches recyclarr-sync.service failing
      #   systemd-timer-stale  catches the timer not having fired in 2 days
      #
      # If this ever needs a dedicated alert, key it on recyclarr-sync and use
      # a timer/staleness shape, not service-down.
    })
  ];
}
