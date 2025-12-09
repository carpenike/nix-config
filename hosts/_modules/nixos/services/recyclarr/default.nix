# Recyclarr Module - TRaSH Guides Automation for Sonarr/Radarr
#
# This module provides automated synchronization of TRaSH guides recommendations
# to Sonarr and Radarr instances, including:
# - Quality definitions (file size limits for quality levels)
# - Quality profiles (upgrade rules and quality cutoffs)
# - Custom formats (release group scoring, codecs, HDR formats, etc.)
# - Media naming conventions (file and folder naming patterns)
#
# **Architecture**:
# - Runs as scheduled systemd timer (not a long-running daemon)
# - Uses Podman containers for isolation
# - Secrets managed via SOPS with environment variable injection
# - Supports multiple Sonarr/Radarr instances simultaneously
#
# **Configuration Levels** (from simple to advanced):
# 1. Templates: Use TRaSH guide presets (recommended for most users)
# 2. Custom Formats: Fine-tune individual format scores
# 3. Quality Profiles: Full control over upgrade rules and thresholds
#
# **Best Practices**:
# - Start with templates, add custom formats only when needed
# - Enable deleteOldCustomFormats to prevent obsolete formats
# - Run dry-run mode first to preview changes
# - Use specific version tags for production (avoid 'latest')
# - Schedule during low-traffic periods (default: daily at random time)
#
# **References**:
# - TRaSH Guides: https://trash-guides.info/
# - Recyclarr Documentation: https://recyclarr.dev/
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

  cfg = config.modules.services.recyclarr;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  datasetPath = "${storageCfg.datasets.parentDataset}/recyclarr";

  # Recursively find replication config from parent datasets
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };

  # Generate YAML configuration for recyclarr manually to preserve !env_var tags
  # pkgs.formats.yaml quotes strings starting with !, so we build YAML directly

  # Helper to generate instance YAML
  mkInstanceYaml = service: name: inst:
    let
      envVarName = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name) + "_${lib.toUpper service}_API_KEY";

      deleteOldCF = lib.optionalString inst.deleteOldCustomFormats ''
        delete_old_custom_formats: true
      '';

      # Media naming for Sonarr
      sonarrMediaNaming = lib.optionalString (service == "sonarr" && inst.mediaNaming != null) (
        let mn = inst.mediaNaming; in ''
          media_naming:
          ${lib.optionalString (mn.series != null) "        series: \"${mn.series}\""}
          ${lib.optionalString (mn.season != null) "        season: \"${mn.season}\""}
          ${lib.optionalString (mn.episodes != null) ''
                  episodes:
                    rename: ${if mn.episodes.rename then "true" else "false"}
          ${lib.optionalString (mn.episodes.standard != null) "          standard: \"${mn.episodes.standard}\""}
          ${lib.optionalString (mn.episodes.daily != null) "          daily: \"${mn.episodes.daily}\""}
          ${lib.optionalString (mn.episodes.anime != null) "          anime: \"${mn.episodes.anime}\""}''}
        ''
      );

      # Media naming for Radarr
      radarrMediaNaming = lib.optionalString (service == "radarr" && inst.mediaNaming != null) (
        let mn = inst.mediaNaming; in ''
          media_naming:
          ${lib.optionalString (mn.folder != null) "        folder: \"${mn.folder}\""}
                  movie:
                    rename: ${if mn.movie.rename then "true" else "false"}
          ${lib.optionalString (mn.movie.standard != null) "          standard: \"${mn.movie.standard}\""}
        ''
      );

      templates = lib.optionalString (inst.templates != [ ]) ''
              include:
        ${lib.concatMapStringsSep "\n" (t: "      - template: ${t}") inst.templates}'';

      customFormats = lib.optionalString (inst.customFormats != [ ]) ''
              custom_formats:
        ${lib.concatMapStringsSep "\n" (cf: "      - ${cf}") inst.customFormats}'';

      qualityProfiles = lib.optionalString (inst.qualityProfiles != [ ]) ''
              quality_profiles:
        ${lib.concatMapStringsSep "\n" (qp: "      - ${qp}") inst.qualityProfiles}'';
    in
    ''
          ${name}:
            base_url: ${inst.baseUrl}
            api_key: !env_var ${envVarName}
            ${deleteOldCF}
            ${if service == "sonarr" then sonarrMediaNaming else radarrMediaNaming}
      ${templates}${customFormats}${qualityProfiles}'';

  configFile = pkgs.writeText "recyclarr.yml" ''
    ${lib.optionalString (cfg.sonarr != {}) ''
    sonarr:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (mkInstanceYaml "sonarr") cfg.sonarr)}''}
    ${lib.optionalString (cfg.radarr != {}) ''
    radarr:
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (mkInstanceYaml "radarr") cfg.radarr)}''}
  '';

  # Instance submodule definition (shared between sonarr and radarr)
  #
  # This module provides type-safe configuration for Recyclarr instances with three levels of control:
  #
  # 1. **Templates** (Recommended for most users):
  #    - Use TRaSH guide presets for quality definitions, profiles, and custom formats
  #    - Simple, maintainable, automatically updated with TRaSH guide changes
  #    - Example: [ "sonarr-quality-definition-series" "sonarr-v4-quality-profile-web-1080p" ]
  #
  # 2. **Custom Formats** (Advanced):
  #    - Fine-grained control over individual custom format scores
  #    - Use when you need to deviate from TRaSH presets
  #    - Requires TRaSH custom format IDs (found in TRaSH guides documentation)
  #
  # 3. **Quality Profiles** (Expert):
  #    - Full control over upgrade rules and scoring thresholds
  #    - Maximum flexibility but requires deep understanding of *arr quality management
  #
  # These options can be combined: templates for baseline + custom formats for tweaks
  instanceSubmodule = lib.types.submodule {
    options = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = "Base URL for the *arr instance (e.g., http://sonarr:8989)";
        example = "http://sonarr.media.svc:8989";
      };

      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the API key (from SOPS secrets)";
        example = "config.sops.secrets.\"sonarr/api-key\".path";
      };

      templates = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          List of TRaSH guide template names to include.

          Common Sonarr templates:
          - sonarr-quality-definition-series
          - sonarr-v4-quality-profile-web-1080p
          - sonarr-v4-quality-profile-web-2160p
          - sonarr-v4-custom-formats-web-1080p

          Common Radarr templates:
          - radarr-quality-definition-movie
          - radarr-quality-profile-hd-bluray-web
          - radarr-quality-profile-uhd-bluray-web
          - radarr-custom-formats-hd-bluray-web
        '';
        example = [
          "sonarr-quality-definition-series"
          "sonarr-v4-quality-profile-web-1080p"
        ];
      };

      customFormats = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            trash_ids = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "List of TRaSH custom format IDs to include";
              example = [ "EBC725268D687D588A20BBC5462E3F" ];
            };

            assign_scores_to = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  name = lib.mkOption {
                    type = lib.types.str;
                    description = "Name of the quality profile to assign scores to";
                    example = "WEB-1080p";
                  };

                  score = lib.mkOption {
                    type = lib.types.int;
                    description = "Score to assign to this custom format in the quality profile";
                    example = 100;
                  };
                };
              });
              default = [ ];
              description = "Quality profiles to assign custom format scores to";
            };
          };
        });
        default = [ ];
        description = ''
          Advanced custom format definitions with scoring.
          Allows fine-grained control over TRaSH custom formats and their scores in quality profiles.
        '';
        example = lib.literalExpression ''
          [
            {
              trash_ids = [ "EBC725268D687D588A20BBC5462E3F" ];
              assign_scores_to = [
                { name = "WEB-1080p"; score = 100; }
              ];
            }
          ]
        '';
      };

      qualityProfiles = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name of the quality profile to configure";
              example = "WEB-1080p";
            };

            reset_unmatched_scores = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Reset scores for custom formats not defined in this configuration";
            };

            upgrade = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  allowed = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Allow automatic upgrades within this quality profile";
                  };

                  until_quality = lib.mkOption {
                    type = lib.types.str;
                    description = "Quality level to upgrade until (e.g., 'WEB 1080p', 'Bluray-1080p')";
                    example = "WEB 1080p";
                  };

                  until_score = lib.mkOption {
                    type = lib.types.int;
                    description = "Custom format score threshold to stop upgrading";
                    example = 10000;
                  };
                };
              });
              default = null;
              description = "Upgrade configuration for this quality profile";
            };

            min_format_score = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Minimum custom format score required for downloads";
            };
          };
        });
        default = [ ];
        description = ''
          Advanced quality profile configurations with upgrade rules and scoring thresholds.
          Provides type-safe configuration for quality management.
        '';
        example = lib.literalExpression ''
          [
            {
              name = "WEB-1080p";
              reset_unmatched_scores = true;
              upgrade = {
                allowed = true;
                until_quality = "WEB 1080p";
                until_score = 10000;
              };
              min_format_score = 0;
            }
          ]
        '';
      };

      deleteOldCustomFormats = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Automatically delete custom formats from Sonarr/Radarr that are no longer in the TRaSH guides.
          This keeps your instance clean and prevents obsolete scoring logic.
          Recommended: true
        '';
      };

      mediaNaming = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            # Sonarr-specific options
            series = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Series folder naming format (Sonarr only)";
              example = "{Series Title} ({Series Year})";
            };

            season = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Season folder naming format (Sonarr only)";
              example = "Season {season:00}";
            };

            episodes = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  rename = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Enable automatic episode renaming";
                  };

                  standard = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Standard episode naming format";
                    example = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} [{Custom Formats}{Quality Full}]";
                  };

                  daily = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Daily episode naming format (news, talk shows)";
                  };

                  anime = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Anime episode naming format";
                  };
                };
              });
              default = null;
              description = "Episode naming configuration (Sonarr only)";
            };

            # Radarr-specific options
            folder = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Movie folder naming format (Radarr only)";
              example = "{Movie Title} ({Release Year})";
            };

            movie = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  rename = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Enable automatic movie renaming";
                  };

                  standard = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Standard movie file naming format";
                    example = "{Movie Title} ({Release Year}) [{Custom Formats}{Quality Full}]";
                  };
                };
              });
              default = null;
              description = "Movie naming configuration (Radarr only)";
            };
          };
        });
        default = null;
        description = ''
          Media naming configuration for consistent file and folder naming.
          Set to null to manage naming manually in the UI.
        '';
      };
    };
  };
in
{
  options.modules.services.recyclarr = {
    enable = lib.mkEnableOption "Recyclarr - TRaSH Guides automation for Sonarr/Radarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/recyclarr";
      description = "Path to Recyclarr data directory containing config and cache";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "922";
      description = "User account under which Recyclarr runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Recyclarr runs";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/recyclarr/recyclarr:7.5.2@sha256:2550848d43a453f2c6adf3582f2198ac719f76670691d76de0819053103ef2fb";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags (e.g., "7.4.1")
        - Use digest pinning for immutability (e.g., "7.4.1@sha256:...")
        - Avoid 'latest' tag for production systems
      '';
      example = "ghcr.io/recyclarr/recyclarr:7.4.1@sha256:f3ad4f59e6e5e4a...";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach this container to.
        Enables DNS resolution to Sonarr/Radarr containers.
        Network must be defined in `modules.virtualization.podman.networks`.
      '';
      example = "media-services";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = ''
        Systemd timer schedule for running Recyclarr sync.
        Can be a systemd.time calendar specification like "daily", "weekly", "hourly", or "*-*-* 03:00:00".
      '';
      example = "*-*-* 03:00:00";
    };

    dryRun = lib.mkEnableOption "preview mode (--preview)";

    logLevel = lib.mkOption {
      type = with lib.types; nullOr (enum [ "debug" "trace" ]);
      default = null;
      description = "Set the log level for Recyclarr CLI";
    };

    # Sonarr instances configuration
    sonarr = lib.mkOption {
      type = lib.types.attrsOf instanceSubmodule;
      default = { };
      description = "Sonarr instances to manage with Recyclarr";
      example = lib.literalExpression ''
        {
          main = {
            baseUrl = "http://sonarr:8989";
            apiKeyFile = config.sops.secrets."sonarr/api-key".path;
            templates = [
              "sonarr-quality-definition-series"
              "sonarr-v4-quality-profile-web-1080p"
            ];
          };
        }
      '';
    };

    # Radarr instances configuration
    radarr = lib.mkOption {
      type = lib.types.attrsOf instanceSubmodule;
      default = { };
      description = "Radarr instances to manage with Recyclarr";
      example = lib.literalExpression ''
        {
          main = {
            baseUrl = "http://radarr:7878";
            apiKeyFile = config.sops.secrets."radarr/api-key".path;
            templates = [
              "radarr-quality-definition-movie"
              "radarr-quality-profile-hd-bluray-web"
            ];
          };
        }
      '';
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Recyclarr";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Recyclarr data.

        Recyclarr stores config.yml and cache that should be backed up.

        Recommended recordsize: 16K
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Recyclarr TRaSH sync failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Recyclarr service events";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.sonarr != { } || cfg.radarr != { };
          message = "Recyclarr requires at least one Sonarr or Radarr instance to be configured";
        }
        {
          assertion = cfg.backup != null -> cfg.backup.enable;
          message = "Recyclarr backup must be explicitly enabled when configured";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
          message = "Recyclarr preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
          message = "Recyclarr preseed.enable requires preseed.passwordFile to be set.";
        }
      ];

      warnings =
        (lib.optional (cfg.backup == null) "Recyclarr has no backup configured. Configuration will not be protected.");

      # Create ZFS dataset for Recyclarr data
      modules.storage.datasets.services.recyclarr = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for configuration files
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user; # Use configured user (UID 922)
        group = cfg.group; # Use configured group (defaults to "media")
        mode = "0750";
      };

      # Create system user for Recyclarr
      users.users.recyclarr = {
        uid = lib.mkDefault (lib.toInt cfg.user);
        group = cfg.group;
        isSystemUser = true;
        description = "Recyclarr service user";
      };

      # Config generator service - creates config before main service starts
      # Similar to qbittorrent pattern: generate config file with correct ownership
      systemd.services.recyclarr-config-generator = {
        description = "Generate Recyclarr configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ "recyclarr-sync.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = pkgs.writeShellScript "generate-recyclarr-config" ''
            set -eu
            CONFIG_FILE="${cfg.dataDir}/recyclarr.yml"

            # Always regenerate config to pick up any Nix changes
            echo "Generating recyclarr config..."
            mkdir -p ${cfg.dataDir}

            # Copy generated config file
            cp ${configFile} "$CONFIG_FILE"
            chmod 640 "$CONFIG_FILE"
            echo "Configuration generated at $CONFIG_FILE"
          '';
        };
      };

      # Systemd service for running Recyclarr sync
      systemd.services.recyclarr-sync =
        let
          # Build command flags
          previewFlag = lib.optionalString cfg.dryRun "--preview";
          logLevelFlag = lib.optionalString (cfg.logLevel != null) "--${cfg.logLevel}";
        in
        lib.mkMerge [
          # Base service configuration
          {
            description = "Recyclarr TRaSH Guides Sync";
            after = [ "network-online.target" "recyclarr-config-generator.service" ];
            wants = [ "network-online.target" "recyclarr-config-generator.service" ];

            serviceConfig = {
              Type = "oneshot";
              # NOTE: Run as root to access SOPS template, then drop privileges to recyclarr user in container
              # This matches the pattern used by sonarr, radarr, and other containerized services
              User = "root";
              Group = "root";

              # Environment file with API keys injected from SOPS
              # This file is generated by sops-nix at activation time with real secrets
              # Format: SONARR_MAIN_SONARR_API_KEY=..., RADARR_MAIN_RADARR_API_KEY=...
              # The placeholder paths are resolved by looking up sops.templates in the host config
              EnvironmentFile =
                let
                  # Try to find the recyclarr-env template path
                  # This will be defined in hosts/forge/secrets.nix as config.sops.templates."recyclarr-env".path
                  templatePath = config.sops.templates."recyclarr-env".path or null;
                in
                if templatePath != null
                then templatePath
                else throw "Recyclarr requires sops.templates.recyclarr-env to be configured in host secrets";

              # Run Recyclarr container in one-shot mode with environment variables
              ExecStart =
                let
                  # Get the path to the SOPS template
                  templatePath = config.sops.templates."recyclarr-env".path or (throw "Recyclarr requires sops.templates.recyclarr-env");
                in
                pkgs.writeShellScript "recyclarr-sync.sh" ''
                  set -euo pipefail

                  # Run recyclarr sync in container
                  # Note: Container runs as recyclarr user, but systemd service runs as root to read secrets
                  # The config directory is mounted from /var/lib/recyclarr which contains recyclarr.yml
                  # Use --env-file to load all environment variables from SOPS template directly into container
                  ${pkgs.podman}/bin/podman run --rm \
                    --name recyclarr-sync \
                    --user ${cfg.user}:${toString config.users.groups.${cfg.group}.gid} \
                    --log-driver=journald \
                    ${lib.optionalString (cfg.podmanNetwork != null) "--network=${cfg.podmanNetwork}"} \
                    -v ${cfg.dataDir}:/config:rw \
                    -e TZ=${cfg.timezone} \
                    --env-file ${templatePath} \
                    ${cfg.image} \
                    sync ${previewFlag} ${logLevelFlag}
                '';

              # Cleanup on failure
              ExecStopPost = ''
                -${pkgs.podman}/bin/podman rm -f recyclarr-sync
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
            unitConfig.OnFailure = [ "notify@recyclarr-failure:%n.service" ];
          })
          # Add preseed dependency
          (lib.mkIf cfg.preseed.enable {
            wants = [ "preseed-recyclarr.service" ];
            after = [ "preseed-recyclarr.service" ];
          })
        ];

      # Systemd timer to trigger the sync service
      systemd.timers.recyclarr-sync = {
        description = "Recyclarr TRaSH Guides Sync Timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "recyclarr-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Recyclarr</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The Recyclarr TRaSH sync service has failed.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u recyclarr-sync -n 100'</code>
            2. Retry sync:
               <code>ssh ''${hostname} 'systemctl start recyclarr-sync'</code>
          '';
        };
      };

      # Backup integration using standardized restic pattern
      modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        recyclarr = {
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
        serviceName = "recyclarr";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "recyclarr-sync.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
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
