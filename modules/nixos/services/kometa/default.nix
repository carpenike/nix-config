# Kometa Module - Plex Metadata Manager
#
# Kometa (formerly Plex Meta Manager) automates metadata management for Plex
# media libraries, including:
# - Custom collections based on TMDb, IMDb, Trakt, and other sources
# - Poster overlays for resolution, audio codec, ratings, etc.
# - Metadata updates for movies, TV shows, and music
# - Playlist management across multiple libraries
#
# **Architecture**:
# - Runs as scheduled systemd timer (not a long-running daemon)
# - Uses Podman containers for isolation
# - Secrets managed via SOPS with environment variable injection
# - Fully declarative configuration generated from Nix options
#
# **Configuration**:
# - Libraries are configured declaratively with collection and overlay defaults
# - TMDb is required for most functionality
# - Trakt/MdbList are optional but enhance collection capabilities
#
# **References**:
# - Kometa Wiki: https://kometa.wiki/
# - GitHub: https://github.com/Kometa-Team/Kometa
{ lib
, mylib
, pkgs
, config
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

  cfg = config.modules.services.kometa;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  datasetPath = "${storageCfg.datasets.parentDataset}/kometa";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # =============================================================================
  # Configuration File Generation
  # =============================================================================

  # Helper to generate library YAML with proper indentation
  mkLibraryYaml = name: libraryConfig: ''
      ${name}:
        remove_overlays: ${if libraryConfig.removeOverlays then "true" else "false"}
    ${lib.optionalString (libraryConfig.collectionFiles != []) ''    collection_files:
    ${lib.concatMapStrings (cf: "      - ${mkFileReference cf}\n") libraryConfig.collectionFiles}''}
    ${lib.optionalString (libraryConfig.overlayFiles != []) ''    overlay_files:
    ${lib.concatMapStrings (of: "      - ${mkFileReference of}\n") libraryConfig.overlayFiles}''}
    ${lib.optionalString (libraryConfig.metadataFiles != []) ''    metadata_files:
    ${lib.concatMapStrings (mf: "      - ${mkFileReference mf}\n") libraryConfig.metadataFiles}''}
    ${lib.optionalString (libraryConfig.operations != null) (mkOperationsYaml libraryConfig.operations)}
  '';

  # Helper to convert file references to YAML
  mkFileReference = ref:
    if ref.type == "default" then
      "default: ${ref.name}${mkTemplateVarsYaml ref.templateVariables}"
    else if ref.type == "file" then
      "file: ${ref.path}"
    else if ref.type == "url" then
      "url: ${ref.url}"
    else if ref.type == "repo" then
      "repo: ${ref.name}"
    else
      throw "Unknown file reference type: ${ref.type}";

  # Helper to format template variables
  mkTemplateVarsYaml = vars:
    if vars == { } then ""
    else "\n          template_variables:\n${lib.concatStrings (lib.mapAttrsToList (k: v: "            ${k}: ${builtins.toString v}\n") vars)}";

  # Helper to generate operations YAML
  mkOperationsYaml = ops: ''
        operations:
    ${lib.optionalString (ops.massGenreUpdate != null) "        mass_genre_update: ${ops.massGenreUpdate}\n"}
    ${lib.optionalString (ops.massAudienceRatingUpdate != null) "        mass_audience_rating_update: ${ops.massAudienceRatingUpdate}\n"}
    ${lib.optionalString (ops.massCriticRatingUpdate != null) "        mass_critic_rating_update: ${ops.massCriticRatingUpdate}\n"}
    ${lib.optionalString (ops.massContentRatingUpdate != null) "        mass_content_rating_update: ${ops.massContentRatingUpdate}\n"}
    ${lib.optionalString (ops.massOriginallyAvailableUpdate != null) "        mass_originally_available_update: ${ops.massOriginallyAvailableUpdate}\n"}
    ${lib.optionalString ops.splitDuplicates "        split_duplicates: true\n"}
    ${lib.optionalString ops.radarrAddAll "        radarr_add_all: true\n"}
    ${lib.optionalString ops.sonarrAddAll "        sonarr_add_all: true\n"}
  '';

  # Helper to generate settings YAML
  mkSettingsYaml = settings: ''
      settings:
        cache: ${if settings.cache then "true" else "false"}
        cache_expiration: ${toString settings.cacheExpiration}
    ${lib.optionalString (settings.assetDirectory != null) "  asset_directory: ${settings.assetDirectory}\n"}
        asset_folders: ${if settings.assetFolders then "true" else "false"}
        create_asset_folders: ${if settings.createAssetFolders then "true" else "false"}
        prioritize_assets: ${if settings.prioritizeAssets then "true" else "false"}
        dimensional_asset_rename: ${if settings.dimensionalAssetRename then "true" else "false"}
        download_url_assets: ${if settings.downloadUrlAssets then "true" else "false"}
        show_missing_season_assets: ${if settings.showMissingSeasonAssets then "true" else "false"}
        show_missing_episode_assets: ${if settings.showMissingEpisodeAssets then "true" else "false"}
        sync_mode: ${settings.syncMode}
        minimum_items: ${toString settings.minimumItems}
        default_collection_order: ${settings.defaultCollectionOrder}
        delete_below_minimum: ${if settings.deleteBelowMinimum then "true" else "false"}
        delete_not_scheduled: ${if settings.deleteNotScheduled then "true" else "false"}
        run_again_delay: ${toString settings.runAgainDelay}
        missing_only_released: ${if settings.missingOnlyReleased then "true" else "false"}
        show_unmanaged: ${if settings.showUnmanaged then "true" else "false"}
        show_unconfigured: ${if settings.showUnconfigured then "true" else "false"}
        show_filtered: ${if settings.showFiltered then "true" else "false"}
        show_options: ${if settings.showOptions then "true" else "false"}
        show_missing: ${if settings.showMissing then "true" else "false"}
        show_missing_assets: ${if settings.showMissingAssets then "true" else "false"}
        save_report: ${if settings.saveReport then "true" else "false"}
        tvdb_language: ${settings.tvdbLanguage}
        item_refresh_delay: ${toString settings.itemRefreshDelay}
        run_order:
    ${lib.concatMapStrings (step: "      - ${step}\n") settings.runOrder}
  '';

  # Generate full config.yml content
  configYaml = pkgs.writeText "kometa-config.yml" ''
    ## Kometa Configuration - Generated by NixOS
    ## Do not edit manually - changes will be overwritten

    # Plex server configuration
    plex:
      url: !env_var KOMETA_PLEX_URL
      token: !env_var KOMETA_PLEX_TOKEN
      timeout: ${toString cfg.plex.timeout}
      db_cache: ${if cfg.plex.dbCache then "true" else "false"}
      clean_bundles: ${if cfg.plex.cleanBundles then "true" else "false"}
      empty_trash: ${if cfg.plex.emptyTrash then "true" else "false"}
      optimize: ${if cfg.plex.optimize then "true" else "false"}

    # TMDb configuration (required)
    tmdb:
      apikey: !env_var KOMETA_TMDB_API_KEY
      language: ${cfg.tmdb.language}
      region: ${cfg.tmdb.region}
      cache_expiration: ${toString cfg.tmdb.cacheExpiration}

    ${lib.optionalString cfg.trakt.enable ''
    # Trakt configuration
    trakt:
      client_id: !env_var KOMETA_TRAKT_CLIENT_ID
      client_secret: !env_var KOMETA_TRAKT_CLIENT_SECRET
      pin:
    ''}

    ${lib.optionalString cfg.mdblist.enable ''
    # MdbList configuration
    mdblist:
      apikey: !env_var KOMETA_MDBLIST_API_KEY
      cache_expiration: ${toString cfg.mdblist.cacheExpiration}
    ''}

    ${lib.optionalString cfg.omdb.enable ''
    # OMDb configuration
    omdb:
      apikey: !env_var KOMETA_OMDB_API_KEY
      cache_expiration: ${toString cfg.omdb.cacheExpiration}
    ''}

    # Library configurations
    libraries:
    ${lib.concatStrings (lib.mapAttrsToList mkLibraryYaml cfg.libraries)}

    ${lib.optionalString (cfg.playlistFiles != []) ''
    # Playlist files
    playlist_files:
    ${lib.concatMapStrings (pf: "  - ${mkFileReference pf}\n") cfg.playlistFiles}
    ''}

    # Global settings
    ${mkSettingsYaml cfg.settings}
  '';

  # =============================================================================
  # Submodule Types
  # =============================================================================

  # File reference submodule for collection/overlay/metadata files
  fileReferenceSubmodule = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [ "default" "file" "url" "repo" ];
        description = "Type of file reference";
        example = "default";
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of default or repo file";
        example = "imdb";
      };

      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to local file";
        example = "config/MyCollections.yml";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "URL to remote file";
      };

      templateVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
        default = { };
        description = "Template variables to customize defaults";
        example = {
          use_separator = false;
          sep_style = "red";
        };
      };
    };
  };

  # Operations submodule for library-level mass updates
  operationsSubmodule = lib.types.submodule {
    options = {
      massGenreUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source for mass genre updates (tmdb, imdb, tvdb, omdb)";
        example = "tmdb";
      };

      massAudienceRatingUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source for audience rating updates (mdb_tmdb, mdb_imdb, etc.)";
        example = "mdb_tmdb";
      };

      massCriticRatingUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source for critic rating updates";
        example = "mdb_metacritic";
      };

      massContentRatingUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source for content rating updates";
        example = "mdb_commonsense";
      };

      massOriginallyAvailableUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source for release date updates";
        example = "tmdb";
      };

      splitDuplicates = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Split duplicate items in the library";
      };

      radarrAddAll = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Add all library movies to Radarr";
      };

      sonarrAddAll = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Add all library shows to Sonarr";
      };
    };
  };

  # Library submodule
  librarySubmodule = lib.types.submodule {
    options = {
      removeOverlays = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set to true to remove all overlays from this library";
      };

      collectionFiles = lib.mkOption {
        type = lib.types.listOf fileReferenceSubmodule;
        default = [ ];
        description = "Collection files to apply to this library";
        example = lib.literalExpression ''
          [
            { type = "default"; name = "basic"; }
            { type = "default"; name = "imdb"; }
          ]
        '';
      };

      overlayFiles = lib.mkOption {
        type = lib.types.listOf fileReferenceSubmodule;
        default = [ ];
        description = "Overlay files to apply to this library";
        example = lib.literalExpression ''
          [
            { type = "default"; name = "ribbon"; }
            { type = "default"; name = "resolution"; templateVariables = { use_edition = false; }; }
          ]
        '';
      };

      metadataFiles = lib.mkOption {
        type = lib.types.listOf fileReferenceSubmodule;
        default = [ ];
        description = "Metadata files to apply to this library";
      };

      operations = lib.mkOption {
        type = lib.types.nullOr operationsSubmodule;
        default = null;
        description = "Library-level operations configuration";
      };
    };
  };

  # Settings submodule
  settingsSubmodule = lib.types.submodule {
    options = {
      cache = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable caching";
      };

      cacheExpiration = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Cache expiration in days";
      };

      assetDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Directory for custom assets";
      };

      assetFolders = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Look for assets in folders named after items";
      };

      createAssetFolders = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create asset folders for items without them";
      };

      prioritizeAssets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Prioritize local assets over online sources";
      };

      dimensionalAssetRename = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Rename assets to include dimensions";
      };

      downloadUrlAssets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Download assets from URLs";
      };

      showMissingSeasonAssets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Show warnings for missing season assets";
      };

      showMissingEpisodeAssets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Show warnings for missing episode assets";
      };

      syncMode = lib.mkOption {
        type = lib.types.enum [ "append" "sync" ];
        default = "append";
        description = "Sync mode for collections (append adds, sync removes)";
      };

      minimumItems = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Minimum items required to create a collection";
      };

      defaultCollectionOrder = lib.mkOption {
        type = lib.types.str;
        default = "release";
        description = "Default collection sort order";
      };

      deleteBelowMinimum = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Delete collections below minimum items";
      };

      deleteNotScheduled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Delete collections not scheduled to run";
      };

      runAgainDelay = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Delay in minutes before running again";
      };

      missingOnlyReleased = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Only show missing items that are already released";
      };

      showUnmanaged = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show unmanaged collections in logs";
      };

      showUnconfigured = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show unconfigured libraries in logs";
      };

      showFiltered = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Show filtered items in logs";
      };

      showOptions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show available options in logs";
      };

      showMissing = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show missing items in logs";
      };

      showMissingAssets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show missing assets in logs";
      };

      saveReport = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Save a report of the run";
      };

      tvdbLanguage = lib.mkOption {
        type = lib.types.str;
        default = "eng";
        description = "Language for TVDb lookups";
      };

      itemRefreshDelay = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Delay in seconds between item refreshes";
      };

      runOrder = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "operations" "metadata" "collections" "overlays" ]);
        default = [ "operations" "metadata" "collections" "overlays" ];
        description = "Order in which to run tasks";
      };
    };
  };

in
{
  options.modules.services.kometa = {
    enable = lib.mkEnableOption "kometa";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/kometa";
      description = "Path to Kometa data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "568";
      description = "User account under which Kometa runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Kometa runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "kometateam/kometa:v2.1.0@sha256:af441b1eeaa3be6a55820f16102d950d12fa52f3bb791b835a6a768385cd3a30";
      description = "Container image for Kometa";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 00/4:00:00";
      description = "Systemd timer schedule for Kometa runs (every 4 hours by default)";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of the Podman network to attach to";
    };

    # =============================================================================
    # Plex Configuration
    # =============================================================================

    plex = {
      url = lib.mkOption {
        type = lib.types.str;
        description = "URL to Plex server";
        example = "http://plex:32400";
      };

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing Plex token";
      };

      timeout = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Timeout in seconds for Plex API requests";
      };

      dbCache = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use database cache";
      };

      cleanBundles = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Clean bundles after run";
      };

      emptyTrash = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Empty trash after run";
      };

      optimize = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Optimize database after run";
      };
    };

    # =============================================================================
    # TMDb Configuration (Required)
    # =============================================================================

    tmdb = {
      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing TMDb API key";
      };

      language = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = "Language for TMDb lookups";
      };

      region = lib.mkOption {
        type = lib.types.str;
        default = "US";
        description = "Region for TMDb lookups";
      };

      cacheExpiration = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Cache expiration in days";
      };
    };

    # =============================================================================
    # Optional Services
    # =============================================================================

    trakt = {
      enable = lib.mkEnableOption "Trakt integration";

      clientIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Trakt client ID";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Trakt client secret";
      };
    };

    mdblist = {
      enable = lib.mkEnableOption "MdbList integration";

      apiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing MdbList API key";
      };

      cacheExpiration = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Cache expiration in days";
      };
    };

    omdb = {
      enable = lib.mkEnableOption "OMDb integration";

      apiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing OMDb API key";
      };

      cacheExpiration = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Cache expiration in days";
      };
    };

    # =============================================================================
    # Libraries Configuration
    # =============================================================================

    libraries = lib.mkOption {
      type = lib.types.attrsOf librarySubmodule;
      default = { };
      description = "Plex libraries to manage (keys must match Plex library names exactly)";
      example = lib.literalExpression ''
        {
          "Movies" = {
            collectionFiles = [
              { type = "default"; name = "basic"; }
              { type = "default"; name = "imdb"; }
            ];
            overlayFiles = [
              { type = "default"; name = "ribbon"; }
            ];
          };
          "TV Shows" = {
            collectionFiles = [
              { type = "default"; name = "basic"; }
            ];
          };
        }
      '';
    };

    playlistFiles = lib.mkOption {
      type = lib.types.listOf fileReferenceSubmodule;
      default = [ ];
      description = "Playlist files to apply across libraries";
    };

    settings = lib.mkOption {
      type = settingsSubmodule;
      default = { };
      description = "Global Kometa settings";
    };

    # =============================================================================
    # Run Options
    # =============================================================================

    runOptions = {
      collections = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run collection operations";
      };

      overlays = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run overlay operations";
      };

      operations = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run library operations";
      };

      metadata = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run metadata operations";
      };
    };

    # =============================================================================
    # Standard Integrations
    # =============================================================================

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic restore before service start";

      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "URL to Restic repository";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic repository password file";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to environment file for Restic (e.g., R2 credentials)";
      };

      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Ordered list of restore methods to attempt";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # =============================================================================
      # Storage Configuration
      # =============================================================================

      modules.storage.datasets.services.kometa = {
        recordsize = "128K";
        compression = "zstd";
      };

      # =============================================================================
      # System User
      # =============================================================================

      users.users.kometa = {
        isSystemUser = true;
        group = cfg.group;
        home = "/var/empty";
        shell = "/run/current-system/sw/bin/nologin";
        description = "Kometa service user";
      };

      # Ensure the media group exists
      users.groups.${cfg.group} = lib.mkDefault { };

      # =============================================================================
      # Systemd Service
      # =============================================================================

      systemd.services.kometa-sync = lib.mkMerge [
        {
          description = "Kometa Plex Metadata Manager Sync";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" "zfs-mount.service" ];
          requires = [ "zfs-mount.service" ];

          path = [ pkgs.podman ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";

            # Resource limits
            MemoryMax = "2G";
            MemoryReservation = "512M";
            CPUQuota = "200%";

            # Security hardening
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ReadWritePaths = [ cfg.dataDir ];

            EnvironmentFile =
              let
                templatePath = config.sops.templates."kometa-env".path or null;
              in
              if templatePath != null
              then templatePath
              else throw "Kometa requires sops.templates.kometa-env to be configured in host secrets";

            ExecStart =
              let
                templatePath = config.sops.templates."kometa-env".path or (throw "Kometa requires sops.templates.kometa-env");
                runFlags = lib.concatStringsSep " " (
                  lib.optional (!cfg.runOptions.collections) "--no-collections"
                  ++ lib.optional (!cfg.runOptions.overlays) "--no-overlays"
                  ++ lib.optional (!cfg.runOptions.operations) "--no-operations"
                  ++ lib.optional (!cfg.runOptions.metadata) "--no-metadata"
                );
              in
              pkgs.writeShellScript "kometa-sync.sh" ''
                set -euo pipefail

                # Copy generated config to data directory
                cp ${configYaml} ${cfg.dataDir}/config.yml
                chown ${cfg.user}:${toString config.users.groups.${cfg.group}.gid} ${cfg.dataDir}/config.yml

                # Run Kometa container
                ${pkgs.podman}/bin/podman run --rm \
                  --name kometa-sync \
                  --user ${cfg.user}:${toString config.users.groups.${cfg.group}.gid} \
                  --log-driver=journald \
                  ${lib.optionalString (cfg.podmanNetwork != null) "--network=${cfg.podmanNetwork}"} \
                  -v ${cfg.dataDir}:/config:rw \
                  -e TZ=${cfg.timezone} \
                  --env-file ${templatePath} \
                  ${cfg.image} \
                  --run ${runFlags}
              '';

            ExecStopPost = ''
              -${pkgs.podman}/bin/podman rm -f kometa-sync
            '';
          };
        }
        # Add Podman network dependency if configured
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        # Add failure notifications
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@kometa-failure:%n.service" ];
        })
        # Add preseed dependency
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-kometa.service" ];
          after = [ "preseed-kometa.service" ];
        })
      ];

      # Systemd timer
      systemd.timers.kometa-sync = {
        description = "Kometa Plex Metadata Manager Timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };

      # =============================================================================
      # Notification Template
      # =============================================================================

      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "kometa-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Kometa</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Kometa Plex metadata sync has failed.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u kometa-sync -n 100'</code>
            2. Retry sync:
               <code>ssh ''${hostname} 'systemctl start kometa-sync'</code>
          '';
        };
      };

      # =============================================================================
      # Backup Integration
      # =============================================================================

      modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        kometa = {
          enable = true;
          paths = [ cfg.dataDir ];
          repository = cfg.backup.repository;
          frequency = cfg.backup.frequency;
          tags = cfg.backup.tags;
          excludePatterns = cfg.backup.excludePatterns;
          useSnapshots = cfg.backup.useSnapshots;
          zfsDataset = cfg.backup.zfsDataset;
        };
      };
    })

    # Preseed service
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "kometa";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "kometa-sync.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
