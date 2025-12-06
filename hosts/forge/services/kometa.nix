# hosts/forge/services/kometa.nix
#
# Host-specific configuration for Kometa (Plex Meta Manager) on 'forge'.
# Kometa automates Plex metadata management including collections, overlays,
# and metadata updates from TMDb, IMDb, Trakt, and other sources.
#
# Libraries configured: TV Shows, Movies
# Schedule: Every 4 hours
# Integrations: TMDb (required), Trakt (optional)

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.kometa.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.kometa = {
        enable = true;

        # Attach to media services network for DNS resolution to Plex
        podmanNetwork = forgeDefaults.podmanNetwork;

        # Run every 4 hours
        schedule = "*-*-* 00/4:00:00";

        # Plex configuration - uses existing plex/token secret
        plex = {
          url = "http://plex:32400";
          tokenFile = config.sops.secrets."plex/token".path;
          timeout = 120;
          cleanBundles = true;
          emptyTrash = true;
          optimize = false;
        };

        # TMDb configuration - required for most functionality
        tmdb = {
          apiKeyFile = config.sops.secrets."tmdb/api-key".path;
          language = "en";
          region = "US";
        };

        # Trakt configuration - enhances collection capabilities
        trakt = {
          enable = true;
          clientIdFile = config.sops.secrets."trakt/client-id".path;
          clientSecretFile = config.sops.secrets."trakt/client-secret".path;
        };

        # Library configurations - must match Plex library names exactly
        libraries = {
          "Movies" = {
            # Use Kometa defaults for popular collections
            collectionFiles = [
              { type = "default"; name = "basic"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "imdb"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "tmdb"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "trakt"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "streaming"; templateVariables = { use_separator = false; }; }
            ];

            # Overlays for resolution, audio, ratings badges
            overlayFiles = [
              { type = "default"; name = "ribbon"; }
              { type = "default"; name = "resolution"; templateVariables = { use_edition = false; }; }
              { type = "default"; name = "audio_codec"; }
            ];

            # Operations for mass metadata updates
            operations = {
              massGenreUpdate = "tmdb";
              massAudienceRatingUpdate = "mdb_tmdb";
              massCriticRatingUpdate = "mdb_metacritic";
            };
          };

          "TV Shows" = {
            # Use Kometa defaults for TV show collections
            collectionFiles = [
              { type = "default"; name = "basic"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "network"; templateVariables = { use_separator = false; }; }
              { type = "default"; name = "streaming"; templateVariables = { use_separator = false; }; }
            ];

            # Overlays for TV shows
            overlayFiles = [
              { type = "default"; name = "ribbon"; }
              { type = "default"; name = "resolution"; }
              { type = "default"; name = "status"; }
            ];

            # Operations for TV metadata
            operations = {
              massGenreUpdate = "tmdb";
            };
          };
        };

        # Global settings
        settings = {
          syncMode = "append";
          minimumItems = 2;
          deleteBelowMinimum = true;
          showMissing = false;
          showUnmanaged = false;
          showUnconfigured = false;
          saveReport = true;
        };

        # Enable backups with ZFS snapshots
        backup = forgeDefaults.mkBackupWithSnapshots "kometa";

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/kometa" =
        forgeDefaults.mkSanoidDataset "kometa";

      # Note: Kometa is a timer-based batch job, not a long-running service.
      # We monitor the timer's last success instead of service-down alerts.
      # The healthcheck-stale alert will fire if the timer hasn't run successfully.
      modules.alerting.rules."kometa-sync-failed" = {
        type = "promql";
        alertname = "KometaSyncFailed";
        expr = ''systemd_timer_last_trigger_seconds{name="kometa-sync.timer"} - systemd_timer_last_trigger_seconds{name="kometa-sync.timer"} offset 1d < -14400'';
        for = "5h";
        severity = "medium";
        labels = {
          service = "kometa";
          category = "media";
        };
        annotations = {
          summary = "Kometa sync has not run in over 5 hours";
          description = "The Kometa Plex metadata sync timer should run every 4 hours but hasn't triggered recently.";
          command = "journalctl -u kometa-sync.service -n 50";
        };
      };
    })
  ];
}
