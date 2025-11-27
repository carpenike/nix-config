{ config, ... }:

let
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  config.modules.services = {
    # qbit_manage - DISABLED: Migrated to tqm
    # tqm provides more powerful expression-based filtering
    # Reference: https://trash-guides.info/qbit_manage/
    qbit-manage = {
      enable = false;
      qbittorrent = {
        host = "localhost";
        port = 8080;
        # login and password = null (auth disabled on local network)
      };

      contentDirectory = "/mnt/data/qb/downloads"; # Root where torrents are stored
      recycleBinEnabled = true; # Safety net for deleted data
      dryRun = false; # Set to true initially to test configuration

      schedule = "*/15 * * * *"; # Good, safe default interval

      # Production-ready configuration based on TRaSH Guides best practices
      extraConfig = {
        # General settings for qbit_manage behavior
        settings = {
          # Tag torrents with tracker errors for easy filtering in qBittorrent
          tracker_error_tag = "issue";

          # Don't manage torrents added in the last 10 minutes (600 seconds)
          # Prevents interference with newly added torrents still being processed
          ignore_torrents_younger_than = 600;
        };

        # --- SEEDING RULES (MOST IMPORTANT) ---
        # CRITICAL: You MUST configure rules for your specific private trackers
        # Reference: https://trash-guides.info/qbit_manage/settings/tracker/
        tracker = {
          # CATCH-ALL DEFAULT: Extremely safe, seeds forever
          # Applies to any tracker NOT explicitly defined below
          "default" = {
            max_ratio = -1; # Never remove based on ratio
            max_seeding_time = -1; # Never remove based on time
            tag = "qbm-default-seed"; # Tag for easy filtering
          };

          # --- EXAMPLE FOR YOUR PRIVATE TRACKERS ---
          # Replace "tracker.example.com" with your actual tracker domain
          # Get tracker domain: Right-click torrent in qBittorrent -> Copy -> Tracker URLs
          # Then extract just the domain (e.g., tracker.domain.com)
          #
          # "tracker.example.com" = {
          #   max_ratio = 2.0;              # Stop seeding at 2.0 ratio
          #   max_seeding_time = 20160;     # OR after 14 days (in minutes)
          #   limit_upload_speed = 0;       # 0 = pause after goals met, -1 = no limit
          #   tag = "qbm-example-tracker";  # Tag for easy filtering
          # };
          #
          # Add more tracker blocks above for each of your private trackers
        };

        # --- CATEGORY & SAVE PATH MANAGEMENT ---
        # Integrates with Sonarr/Radarr/Lidarr stack
        cat = {
          "radarr" = {
            save_path = "/mnt/data/qb/downloads/radarr";
          };
          "sonarr" = {
            save_path = "/mnt/data/qb/downloads/sonarr";
          };
          "lidarr" = {
            save_path = "/mnt/data/qb/downloads/lidarr";
          };
          "readarr" = {
            save_path = "/mnt/data/qb/downloads/readarr";
          };

          # CRITICAL: Tell qbit_manage to IGNORE cross-seed categories
          # This prevents conflicts with tqm which manages these torrents
          "cross-seed" = {
            managed = false; # Don't touch cross-seeded torrents
          };
          "xseeds" = {
            managed = false; # Alternative cross-seed category name
          };
        };

        # --- ORPHANED FILE CLEANUP (DISABLED BY DEFAULT) ---
        # Finds files not linked to any torrent in qBittorrent
        # DANGEROUS: Only enable after you're confident in your setup
        # When enabled, moves orphaned files to recycleBinDir
        #
        # orphaned = {
        #   exclude_patterns = [
        #     "*.!qB"        # qBittorrent temp files
        #     "*.parts"      # Partial downloads
        #     "*.fastresume" # Resume data
        #     "*.torrent"    # Torrent files
        #     "*.magnet"     # Magnet links
        #   ];
        # };
      };

      backup = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/qbit-manage";
      };

      notifications = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "qbit_manage torrent lifecycle management failed on forge";
        };
      };

      preseed =
        if resticEnabled then {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          restoreMethods = [ "syncoid" "local" ];
        } else { };
    };
  };
}
