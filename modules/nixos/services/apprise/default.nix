# Apprise API - Notification gateway service
#
# Apprise API provides a REST API interface to the Apprise notification library,
# allowing services to send notifications to multiple platforms (Pushover, Slack,
# Discord, Email, etc.) via HTTP requests.
#
# Usage in Tracearr and other services:
#   - Set webhook URL to http://apprise:8000/notify/{key}
#   - Set webhook format to "apprise"
#   - Apprise routes notifications to configured backends (Pushover, etc.)
#
# API Endpoints:
#   GET  /status           - Health check
#   POST /notify           - Stateless notification (URLs in body)
#   POST /notify/{key}     - Stateful notification (URLs configured per key)
#   GET  /json/urls/{key}  - Get URLs for a key
#   POST /add/{key}        - Add URLs to a key
#
{ config, lib, pkgs, mylib, podmanLib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  cfg = config.modules.services.apprise;
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;

  # Service identity
  serviceName = "apprise";
  serviceIds = mylib.serviceUids.${serviceName};
in
{
  options.modules.services.apprise = {
    enable = mkEnableOption "Apprise API notification gateway";

    image = mkOption {
      type = types.str;
      # Note: Container version (1.3.0) differs from Python apprise package version (1.9.5)
      # The apprise-api container is versioned independently
      default = "docker.io/caronc/apprise:1.3.0@sha256:e365025a7bf1fed39ef66b5f22c9855d500ee7bdea27441365e5b95ea972e843";
      description = "Container image for Apprise API";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/${serviceName}";
      description = "Data directory for Apprise configuration and state";
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = "Port for Apprise API to listen on";
    };

    user = mkOption {
      type = types.str;
      default = serviceName;
      description = "User to run Apprise as";
    };

    group = mkOption {
      type = types.str;
      default = serviceName;
      description = "Group to run Apprise as";
    };

    uid = mkOption {
      type = types.int;
      default = serviceIds.uid;
      description = "UID for the Apprise user";
    };

    gid = mkOption {
      type = types.int;
      default = serviceIds.gid;
      description = "GID for the Apprise group";
    };

    timezone = mkOption {
      type = types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone for the Apprise container";
    };

    statefulMode = mkOption {
      type = types.enum [ "disabled" "simple" "hash" ];
      default = "simple";
      description = ''
        Stateful mode for Apprise:
        - disabled: No persistent configuration, URLs must be provided with each request
        - simple: URLs stored by simple key name (e.g., "default", "alerts")
        - hash: URLs stored by hash for more security
      '';
    };

    workerCount = mkOption {
      type = types.int;
      default = 1;
      description = "Number of worker processes for handling requests";
    };

    enableAdmin = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the web-based admin interface for managing notification URLs";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables to pass to the container";
    };

    resources = mkOption {
      type = sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "256m";
        memoryReservation = "128m";
        cpus = "0.5";
      };
      description = "Container resource limits";
    };

    healthcheck = mkOption {
      type = sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "10s";
      };
      description = "Container healthcheck configuration";
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        labels = {
          service = serviceName;
          service_type = "notification";
        };
        containerDriver = "journald";
      };
      description = "Logging configuration for Promtail";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration";
    };

    preseed = {
      enable = mkEnableOption "automatic restore before first start";

      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "URL to Restic repository for preseed restore";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing Restic repository password";
      };

      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Ordered list of restore methods to try during preseed";
      };
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      # User and group
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        uid = cfg.uid;
        home = "/var/empty";
        createHome = false;
        description = "Apprise API notification service";
      };

      users.groups.${cfg.group} = {
        gid = cfg.gid;
      };

      # Storage dataset configuration
      # Note: OCI containers don't support StateDirectory, so we explicitly set
      # permissions via tmpfiles and the storage module
      modules.storage.datasets.services.apprise = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Small files for config
        compression = "lz4";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Directory permissions for subdirectories
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/attach 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/plugin 0750 ${cfg.user} ${cfg.group} - -"
      ];

      # Container definition using podmanLib.mkContainer for standard logging
      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        user = "${toString cfg.uid}:${toString cfg.gid}";

        environment = {
          TZ = cfg.timezone;
          PUID = toString cfg.uid;
          PGID = toString cfg.gid;
          APPRISE_STATEFUL_MODE = cfg.statefulMode;
          APPRISE_WORKER_COUNT = toString cfg.workerCount;
          APPRISE_ADMIN = if cfg.enableAdmin then "y" else "n";
        } // cfg.extraEnvironment;

        volumes = [
          "${cfg.dataDir}/config:/config:rw"
          "${cfg.dataDir}/attach:/attach:rw"
          "${cfg.dataDir}/plugin:/plugin:ro"
        ];

        # Resource limits (handled by mkContainer)
        resources = cfg.resources;

        extraOptions =
          # Healthcheck
          lib.optionals cfg.healthcheck.enable [
            ''--health-cmd=curl -sf http://localhost:8000/status || exit 1''
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
          ]
          ++ [
            "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m"
            "--cap-drop=ALL"
            "--security-opt=no-new-privileges:true"
            "--read-only"
          ];

        ports = [
          "127.0.0.1:${toString cfg.port}:8000"
        ];
      };

      # Systemd service overrides
      systemd.services."podman-${serviceName}" = lib.mkMerge [
        {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Restart = "always";
            RestartSec = "10s";
          };
        }
        # Add dependency on preseed service if enabled
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-apprise.service" ];
          after = [ "preseed-apprise.service" ];
        })
      ];

      # Reverse proxy integration
      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };
        extraConfig = cfg.reverseProxy.extraConfig or "";
      };
    })

    # Preseed / disaster recovery service
    (mkIf (cfg.enable && cfg.preseed.enable) (
      let
        storageCfg = config.modules.storage;
        datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";
        replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
      in
      storageHelpers.mkPreseedService {
        inherit serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "podman-${serviceName}.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "lz4";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
