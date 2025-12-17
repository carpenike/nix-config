{ lib, mylib, pkgs, config, ... }:

let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  cfg = config.modules.services.frigate;
  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };
  parentDataset = datasetsCfg.parentDataset or null;
  datasetPath = if parentDataset == null then null else "${parentDataset}/frigate";
  mainServiceUnit = "frigate.service";
  hasCentralizedNotifications = config.modules.notifications.enable or false;
  defaultHostname =
    let
      domain = config.networking.domain or null;
    in
    if domain == null || domain == "" then "frigate.local" else "frigate.${domain}";
  envDir = "/run/frigate";
  mqttEnvFile = "${envDir}/mqtt.env";

  recordingSettings = lib.optionalAttrs cfg.recordingPolicy.enable {
    record = {
      enabled = true;
      retain = {
        days = cfg.recordingPolicy.retainDays;
        mode = cfg.recordingPolicy.mode;
      };
      events.retain = {
        default = cfg.recordingPolicy.eventRetainDays;
        mode = "motion";
      };
    };
    snapshots = {
      enabled = cfg.recordingPolicy.snapshotRetainDays > 0;
      retain = {
        default = cfg.recordingPolicy.snapshotRetainDays;
        mode = "motion";
      };
    };
  };

  mqttSettings = lib.optionalAttrs cfg.mqtt.enable {
    mqtt = {
      enabled = true;
      host = cfg.mqtt.host;
      port = cfg.mqtt.port;
      topic_prefix = cfg.mqtt.topicPrefix;
      user = cfg.mqtt.username;
      password = "{FRIGATE_MQTT_PASSWORD}";
      client_id = cfg.mqtt.clientId;
    };
  };

  detectorSettings = lib.optionalAttrs (cfg.detectors != { }) {
    detectors = cfg.detectors;
  };

  baseSettings = {
    media_dir = cfg.mediaDir;
    database.path = "${cfg.dataDir}/frigate.db";
  };

  mergedSettings = lib.recursiveUpdate baseSettings (
    recordingSettings
    // mqttSettings
    // detectorSettings
  );

  reverseProxyHost =
    if cfg.reverseProxy != null && cfg.reverseProxy.hostName != null then cfg.reverseProxy.hostName else cfg.hostname;

  frigateUser = "frigate";
  frigateGroup = "frigate";
  recordingsPath = "${cfg.mediaDir}/recordings";

in
{
  options.modules.services.frigate = {
    enable = lib.mkEnableOption "Frigate NVR (native module wrapper)";

    package = lib.mkPackageOption pkgs "frigate" { };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = defaultHostname;
      description = "Hostname used by the bundled nginx vhost.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/frigate";
      description = "Configuration and metadata directory.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/frigate";
      description = "Base directory for recordings, clips, snapshots, and exports.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/frigate";
      description = "Cache directory used by Frigate and nginx.";
    };

    manageStorage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create ZFS datasets for Frigate config + recordings via modules.storage.";
    };

    detectors = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Detector definitions passed through to Frigate (e.g., Coral edgetpu).";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Raw Frigate configuration merged on top of module defaults.";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Optional reverse proxy registration for Caddy.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "frigate.service";
        labels = {
          service = "frigate";
          service_type = "nvr";
        };
      };
      description = "Log shipping metadata for Frigate logs.";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "Frigate service failed on ${config.networking.hostName}";
      };
      description = "Notification hooks for service failures.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Optional Restic backup policy for Frigate state.";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
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

    mqtt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable MQTT integration for Home Assistant automations.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "MQTT broker hostname.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "MQTT broker port.";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "frigate";
        description = "Service account used to authenticate to EMQX.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to MQTT password secret (SOPS).";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "${config.networking.hostName}-frigate";
        description = "MQTT client ID for connection tracking.";
      };

      topicPrefix = lib.mkOption {
        type = lib.types.str;
        default = "frigate";
        description = "Base topic used for status/events.";
      };

      registerEmqxIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically provision MQTT user + ACLs via EMQX integration.";
      };

      allowedTopics = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "frigate/#" ];
        description = "Topic filters granted to the Frigate MQTT user.";
      };
    };

    recordingPolicy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Emit sane defaults for recordings/snapshots retention.";
      };
      retainDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Number of days to retain continuous recordings.";
      };
      mode = lib.mkOption {
        type = lib.types.enum [ "all" "motion" "active_objects" ];
        default = "all";
        description = "Recording retention mode per Frigate docs.";
      };
      eventRetainDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Retention for motion-triggered events.";
      };
      snapshotRetainDays = lib.mkOption {
        type = lib.types.ints.nonNegative;
        default = 30;
        description = "Retention for generated snapshots.";
      };
    };

    go2rtc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the companion go2rtc service for restreaming.";
      };
      settings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "go2rtc configuration (passed to services.go2rtc).";
      };
    };

    ensureSystemUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the frigate system user/group even when the upstream service is disabled (useful when other modules reference the account).";
    };
  };

  config =
    lib.mkMerge [
      (lib.mkIf cfg.ensureSystemUser {
        users.users.${frigateUser} = {
          isSystemUser = true;
          group = frigateGroup;
          home = cfg.dataDir;
          description = "Frigate service account";
        };

        users.groups.${frigateGroup} = { };
      })

      (lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = !(cfg.mqtt.enable && cfg.mqtt.passwordFile == null);
            message = "modules.services.frigate.mqtt.passwordFile must be set when MQTT is enabled.";
          }
        ] ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.repositoryUrl != "";
          message = "Frigate preseed.enable requires preseed.repositoryUrl to be set.";
        }) ++ (lib.optional cfg.preseed.enable {
          assertion = cfg.preseed.passwordFile != null;
          message = "Frigate preseed.enable requires preseed.passwordFile to be set.";
        });

        services.frigate = {
          enable = true;
          hostname = cfg.hostname;
          package = cfg.package;
          settings = lib.recursiveUpdate mergedSettings cfg.settings;
        };

        services.go2rtc = lib.mkIf cfg.go2rtc.enable {
          enable = true;
          settings = cfg.go2rtc.settings;
        };

        systemd.services.frigate = lib.mkMerge [
          # Preseed dependency
          (lib.mkIf cfg.preseed.enable {
            wants = [ "preseed-frigate.service" ];
            after = [ "preseed-frigate.service" ];
          })
          # MQTT environment setup
          (lib.mkIf cfg.mqtt.enable {
            serviceConfig.ExecStartPre = lib.mkAfter [
              (pkgs.writeShellScript "frigate-render-mqtt-env" ''
                                set -euo pipefail
                                umask 077
                                ${pkgs.coreutils}/bin/install -d -m 0700 ${envDir}
                                secret="$(${pkgs.coreutils}/bin/tr -d '\n' < ${cfg.mqtt.passwordFile})"
                                cat > ${mqttEnvFile} <<EOF
                FRIGATE_MQTT_PASSWORD=$secret
                EOF
              '')
            ];
            serviceConfig.EnvironmentFile = lib.mkAfter [ mqttEnvFile ];
          })
        ];

        modules.services.caddy.virtualHosts.frigate = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = reverseProxyHost;
          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = 5000;
          };
          auth = cfg.reverseProxy.auth;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        modules.services.emqx.integrations.frigate = lib.mkIf (cfg.mqtt.enable && cfg.mqtt.registerEmqxIntegration) {
          users = [
            {
              username = cfg.mqtt.username;
              passwordFile = cfg.mqtt.passwordFile;
              tags = [ "frigate" "nvr" ];
            }
          ];
          acls = [
            {
              permission = "allow";
              action = "pubsub";
              subject = {
                kind = "user";
                value = cfg.mqtt.username;
              };
              topics = cfg.mqtt.allowedTopics;
              comment = "Frigate publishes detections + consumes commands";
            }
          ];
        };

        modules.storage.datasets.services = lib.mkIf cfg.manageStorage {
          frigate = {
            mountpoint = cfg.dataDir;
            recordsize = "16K";
            compression = "zstd";
            properties = { "com.sun:auto-snapshot" = "true"; };
            owner = frigateUser;
            group = frigateGroup;
            mode = "0750";
          };
          "frigate-recordings" = {
            mountpoint = recordingsPath;
            recordsize = "1M";
            compression = "lz4";
            properties = {
              "com.sun:auto-snapshot" = "true";
              atime = "off";
            };
            owner = frigateUser;
            group = frigateGroup;
            mode = "0750";
          };
        };

        modules.backup.restic.jobs.frigate = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          enable = true;
          repository = cfg.backup.repository;
          paths = [ cfg.dataDir ];
          excludePatterns = (cfg.backup.excludePatterns or [ ]) ++ [
            "${recordingsPath}/**"
            "${cfg.cacheDir}/**"
          ];
          frequency = cfg.backup.frequency or "daily";
          tags = cfg.backup.tags or [ "frigate" "nvr" ];
          useSnapshots = cfg.backup.useSnapshots or true;
          zfsDataset = cfg.backup.zfsDataset or (if parentDataset == null then null else "${parentDataset}/frigate");
        };
      })

      # Preseed service for disaster recovery
      (lib.mkIf (cfg.enable && cfg.preseed.enable) (
        storageHelpers.mkPreseedService {
          serviceName = "frigate";
          dataset = datasetPath;
          mountpoint = cfg.dataDir;
          mainServiceUnit = mainServiceUnit;
          replicationCfg = null; # Replication config handled at host level
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
          owner = frigateUser;
          group = frigateGroup;
        }
      ))
    ];
}
