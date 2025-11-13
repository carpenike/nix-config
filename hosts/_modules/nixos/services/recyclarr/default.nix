{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

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
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
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

  # Generate YAML configuration for recyclarr
  yamlFormat = pkgs.formats.yaml {};

  # Build the recyclarr.yml configuration
  recyclarrConfig = {
    # Sonarr instances
    sonarr = lib.mapAttrs (name: inst: {
      base_url = inst.baseUrl;
      api_key = "\${${lib.toUpper name}_SONARR_API_KEY}";
    } // lib.optionalAttrs (inst.templates != []) {
      include = map (t: { template = t; }) inst.templates;
    } // lib.optionalAttrs (inst.customFormats != []) {
      custom_formats = inst.customFormats;
    } // lib.optionalAttrs (inst.qualityProfiles != []) {
      quality_profiles = inst.qualityProfiles;
    }) cfg.sonarr;

    # Radarr instances
    radarr = lib.mapAttrs (name: inst: {
      base_url = inst.baseUrl;
      api_key = "\${${lib.toUpper name}_RADARR_API_KEY}";
    } // lib.optionalAttrs (inst.templates != []) {
      include = map (t: { template = t; }) inst.templates;
    } // lib.optionalAttrs (inst.customFormats != []) {
      custom_formats = inst.customFormats;
    } // lib.optionalAttrs (inst.qualityProfiles != []) {
      quality_profiles = inst.qualityProfiles;
    }) cfg.radarr;
  };

  configFile = yamlFormat.generate "recyclarr.yml" recyclarrConfig;

  # Instance submodule definition (shared between sonarr and radarr)
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
        default = [];
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
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = ''
          Advanced custom format definitions with scoring.
          Each entry should have trash_ids and assign_scores_to attributes.
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
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = "Advanced quality profile configurations";
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
      default = "ghcr.io/recyclarr/recyclarr:latest";
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
      default = {};
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
      default = {};
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
          assertion = cfg.sonarr != {} || cfg.radarr != {};
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
        recordsize = "16K";  # Optimal for configuration files
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;  # Use configured user (UID 922)
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

      # Write recyclarr.yml to config directory
      # This file will be mounted into the container
      environment.etc."recyclarr/recyclarr.yml" = {
        source = configFile;
        mode = "0640";
        user = cfg.user;
        group = cfg.group;
      };

      # Create environment file with API keys for runtime substitution
      # This file sources all API keys from SOPS-managed files
      systemd.services.recyclarr-sync = let
        envScript = pkgs.writeShellScript "recyclarr-env.sh" ''
          set -euo pipefail

          ${lib.concatStringsSep "\n" (
            (lib.mapAttrsToList (name: inst:
              "export ${lib.toUpper name}_SONARR_API_KEY=$(cat ${inst.apiKeyFile})"
            ) cfg.sonarr) ++
            (lib.mapAttrsToList (name: inst:
              "export ${lib.toUpper name}_RADARR_API_KEY=$(cat ${inst.apiKeyFile})"
            ) cfg.radarr)
          )}
        '';

        # Build command flags
        previewFlag = lib.optionalString cfg.dryRun "--preview";
        logLevelFlag = lib.optionalString (cfg.logLevel != null) "--${cfg.logLevel}";
      in lib.mkMerge [
        # Base service configuration
        {
          description = "Recyclarr TRaSH Guides Sync";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            User = cfg.user;
            Group = cfg.group;

            # Run Recyclarr container in one-shot mode with environment variables
            ExecStart = pkgs.writeShellScript "recyclarr-sync.sh" ''
              set -euo pipefail

              # Source API keys into environment
              source ${envScript}

              # Run recyclarr sync in container
              ${pkgs.podman}/bin/podman run --rm \
                --name recyclarr-sync \
                --user ${cfg.user}:${toString config.users.groups.${cfg.group}.gid} \
                --log-driver=journald \
                ${lib.optionalString (cfg.podmanNetwork != null) "--network=${cfg.podmanNetwork}"} \
                -v /etc/recyclarr/recyclarr.yml:/config/recyclarr.yml:ro \
                -v ${cfg.dataDir}:/config:rw \
                -e TZ=${cfg.timezone} \
                ${lib.concatStringsSep " " (
                  (lib.mapAttrsToList (name: _:
                    "-e ${lib.toUpper name}_SONARR_API_KEY"
                  ) cfg.sonarr) ++
                  (lib.mapAttrsToList (name: _:
                    "-e ${lib.toUpper name}_RADARR_API_KEY"
                  ) cfg.radarr)
                )} \
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
