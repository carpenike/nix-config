# hosts/forge/services/tqm.nix
#
# Host-specific configuration for tqm (torrent lifecycle management) on 'forge'.
# tqm automates torrent cleanup, relabeling, and ratio management.
#
# ARCHITECTURE NOTE:
# tqm is a stateless utility that runs as scheduled oneshot systemd timers.
# All configuration is generated from Nix; there is no persistent state to back up.
# Therefore, this service intentionally does NOT include:
#   - Sanoid/Syncoid ZFS snapshots (no data to snapshot)
#   - Backup configuration (no data to backup)
#   - Preseed/DR configuration (nothing to restore)
#   - Service-down alerts (oneshot timers, not long-running daemons)
#
# The timers (tqm-clean, tqm-relabel, etc.) can be monitored via systemd timer
# metrics if desired, but failure is non-critical (just delays torrent cleanup).

{ lib, ... }:
{
  # Standard structure maintained for consistency, though tqm has no
  # infrastructure contributions (it's stateless oneshot timers)
  config = lib.mkMerge [
    {
      modules.services.tqm = {
        # tqm - Comprehensive torrent lifecycle management
        # GEMINI PRO OPTIMIZED CONFIGURATION (Nov 2025)
        # Based on deep analysis of 421 torrent environment:
        # - 77% BTN (landof.tv) torrents requiring careful ratio management
        # - 67% under 1.0 ratio (283 torrents) - strategic removal needed
        # - 422GB stalled downloads - quarantine approach
        # - Phased implementation: tag first, remove later
        # Reference: https://github.com/autobrr/tqm
        enable = true;

        client = {
          type = "qbittorrent";
          host = "localhost";
          port = 8080;
          user = null; # Auth disabled on local network
          password = null;
          downloadPath = "/mnt/data/qb/downloads";
          downloadPathMapping = {
            "/downloads" = "/mnt/data/qb/downloads";
          };
          enableAutoTmmAfterRelabel = true;
          createTagsUpfront = false;
        };

        bypassIgnoreIfUnregistered = true;

        filters = {
          default = {
            # Hardlink protection for clean and retag commands
            MapHardlinksFor = [ "clean" "retag" ];

            DeleteData = true;

            # ========================================================================
            # IGNORE FILTERS - Protection Layer (NEVER touch these torrents)
            # ========================================================================
            ignore = [
              # --- Core Protection ---
              "IsTrackerDown()" # Skip when tracker is down
              "Downloaded == false" # Skip incomplete downloads
              "SeedingHours < 26" # Minimum 26 hours before considering removal
              "HardlinkedOutsideClient == true" # CRITICAL: Never remove hardlinked content

              # --- Manual Protection Tags ---
              "HasAnyTag(\"tqm-keep\")" # User-applied protection
              "HasAnyTag(\"tqm-permaseed\")" # Auto-identified permanent seeds

              # --- BTN (landof.tv) - 326 torrents, 77% of collection ---
              # Protect until: ratio >= 1.0 OR seed time >= 14 days
              "TrackerName contains 'landof.tv' && (Ratio < 1.0 || SeedingDays < 14)"

              # --- PTP/RED - Ratio-Focused Trackers ---
              "(TrackerName contains 'passthepopcorn' || TrackerName contains 'redacted') && Ratio < 1.5"

              # --- MyAnonamouse (MAM) - Seed Time Focused ---
              "TrackerName contains 'myanonamouse' && SeedingDays < 30"

              # --- FileList/TorrentLeech - Balanced Approach ---
              "(TrackerName contains 'filelist' || TrackerName contains 'torrentleech') && (Ratio < 1.0 || SeedingDays < 7)"

              # --- Blutopia/MoreThanTV/SceneTime/Anthelion - Standard Private ---
              "(TrackerName contains 'blutopia' || TrackerName contains 'morethantv' || TrackerName contains 'scenetime' || TrackerName contains 'anthelion') && (Ratio < 1.0 || SeedingDays < 7)"
            ];

            # ========================================================================
            # REMOVE FILTERS - DESTRUCTIVE (Phased Implementation)
            # ========================================================================
            remove = [
              # --- PHASE 1: Active (Safe) ---
              "IsUnregistered()" # Always remove confirmed unregistered torrents

              # --- PHASE 2: Two-Step Removal (COMMENTED OUT - Enable after monitoring) ---
              # Uncomment after 1-2 weeks of tag monitoring to enable graduated removal
              # "HasAnyTag(['tqm-removal-candidate']) && TagAddedDays('tqm-removal-candidate') > 1"

              # --- PHASE 3: Space-Based Removal (COMMENTED OUT - Enable when needed) ---
              # Uncomment when space management becomes critical
              # "FreeSpaceSet == true && FreeSpaceGB() < 100 && Ratio > 2.0 && SeedingDays > 60 && Seeds > 20"
            ];

            # ========================================================================
            # PAUSE FILTERS - Performance Optimization
            # ========================================================================
            pause = [
              # Always pause public torrents (no ratio obligation)
              "IsPrivate == false"

              # Pause low-ratio long-seeders on private trackers
              "Ratio < 0.5 && SeedingDays > 7"

              # Performance: Pause highly inactive torrents that have met minimum ratio
              "LastActivityDays > 30 && Ratio > 1.5"
            ];

            # ========================================================================
            # LABEL RULES - Category Management
            # ========================================================================
            label = [
              # Move stalled downloads to investigation category (422GB problem)
              # Note: Category must be created in qBittorrent first (slashes ARE allowed for subcategories)
              {
                name = "tqm/stalled";
                update = [
                  "HasAnyTag(\"tqm-investigate\")"
                ];
              }

              # Move torrents with missing files to cleanup category (commented out - feature not available yet)
              # {
              #   name = "tqm/cleanup";
              #   update = [
              #     "HasAnyTag(\"tqm-missing-files\")"
              #   ];
              # }
            ];

            # ========================================================================
            # TAG RULES - Monitoring, Workflow, and Upload Limiting
            # ========================================================================
            tag = [
              # --- Investigation Tags (Non-Destructive) ---

              # Tag stalled/incomplete downloads for manual review (addresses 422GB of stuck downloads)
              # Note: Using Downloaded==false as proxy for incomplete torrents
              {
                name = "tqm-investigate";
                mode = "add";
                update = [
                  "Downloaded == false && AddedDays > 30"
                ];
              }

              # Tag torrents with missing files (if supported by tqm version)
              # {
              #   name = "tqm-missing-files";
              #   mode = "add";
              #   update = [
              #     "HasMissingFiles()"
              #   ];
              # }

              # --- Permaseed Identification ---

              # Tag torrents that should be permanently seeded
              # Criteria: old + cross-seeded, OR rare (low seed count)
              {
                name = "tqm-permaseed";
                mode = "add";
                update = [
                  "HasAllTags(\"activity:>180d\", \"cross-seed\") || Seeds < 3"
                ];
              }

              # --- Two-Step Removal Workflow (Step 1: Tag Candidates) ---

              # BTN torrents that have exceeded minimums and are well-seeded
              {
                name = "tqm-removal-candidate";
                mode = "add";
                update = [
                  "TrackerName contains 'landof.tv' && Ratio >= 1.5 && SeedingDays >= 21 && Seeds > 10"
                ];
              }

              # Other private trackers with high ratio/seed time
              {
                name = "tqm-removal-candidate";
                mode = "add";
                update = [
                  "IsPrivate == true && !(TrackerName contains 'landof.tv') && Ratio > 3.0 && SeedingDays > 90 && Seeds > 10"
                ];
              }

              # --- Priority Tags ---

              # Low-priority: high ratio, well-seeded, inactive
              {
                name = "tqm-lowpriority";
                mode = "add";
                update = [
                  "HasAnyTag(\"activity:>180d\", \"inactive\") && Ratio > 2.0 && Seeds > 10"
                ];
              }

              # Active torrents with low seed count (keep seeding!)
              {
                name = "low-seed";
                mode = "add";
                update = [
                  "Seeds <= 3"
                ];
              }

              # Inactive torrents (no activity in 30+ days)
              {
                name = "inactive";
                mode = "add";
                update = [
                  "LastActivityDays > 30"
                ];
              }

              # --- Upload Speed Limiting ---

              # Limit public torrents to 100 KB/s
              {
                name = "public-limited";
                mode = "full";
                uploadKb = 100;
                update = [
                  "IsPrivate == false"
                ];
              }

              # Limit low-priority torrents to 500 KB/s (save bandwidth for active)
              {
                name = "lowpriority-limited";
                mode = "full";
                uploadKb = 500;
                update = [
                  "HasAnyTag(\"tqm-lowpriority\")"
                ];
              }
            ];

            # ========================================================================
            # ORPHAN FILE DETECTION
            # ========================================================================
            orphan = {
              grace_period = "10m";
              ignore_paths = [
                "/mnt/data/qb/downloads/tv-4k"
                "/mnt/data/qb/downloads/movie-4k"
              ];
            };
          };
        };

        # Schedules optimized for 421 torrent collection
        schedules = {
          clean = "*:0/15"; # Every 15 min - remove torrents (conservative frequency)
          relabel = "*:0/30"; # Every 30 min - fix categories
          retag = "*:0/30"; # Every 30 min - update tags (critical for workflows)
          orphan = "daily"; # Daily at midnight - cleanup orphans
          pause = "*:0/30"; # Every 30 min - pause torrents (performance optimization)
        };
      };
    }

    # Infrastructure contributions intentionally omitted - see header comment
    # tqm is stateless (oneshot timers), no sanoid/backup/alerts needed
  ];
}
