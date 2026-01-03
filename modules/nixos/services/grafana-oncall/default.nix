# NixOS module for Grafana OnCall
#
# Grafana OnCall is an open-source incident response and on-call management
# platform that integrates deeply with Grafana. It provides:
# - Alert routing and escalation policies
# - On-call schedule management
# - Integration with Slack, Telegram, and other notification channels
# - Direct integration with Grafana for unified observability
#
# This module deploys OnCall as a multi-container service:
# - engine: Main API/web server
# - celery: Background task worker
# - Redis: Message broker (bundled)
#
# Architecture:
# - Uses SQLite by default (simple, sufficient for small teams)
# - Can optionally use PostgreSQL for larger deployments
# - Integrates with existing Grafana via plugin
#
{ config, lib, mylib, pkgs, ... }:
with lib;
let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  # Import service UIDs from centralized registry
  serviceIds = mylib.serviceUids.grafana-oncall;

  cfg = config.modules.services.grafana-oncall;
  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };

  serviceName = "grafana-oncall";
  backend = config.virtualisation.oci-containers.backend;

  # Container service names
  engineServiceName = "${backend}-${serviceName}-engine";
  celeryServiceName = "${backend}-${serviceName}-celery";
  redisServiceName = "${backend}-${serviceName}-redis";
  migrationServiceName = "${backend}-${serviceName}-migration";

  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Network name for inter-container communication
  networkName = "${serviceName}-network";

  # Build environment variables for containers
  oncallEnvironment = {
    DATABASE_TYPE = cfg.database.type;
    BASE_URL = cfg.baseUrl;
    GRAFANA_API_URL = cfg.grafanaApiUrl;
    DJANGO_SETTINGS_MODULE = "settings.hobby";
    BROKER_TYPE = "redis";
    # Use container hostname for Redis (internal network communication)
    REDIS_URI = "redis://${serviceName}-redis:${toString cfg.redis.port}/0";

    # Celery settings
    CELERY_WORKER_QUEUE = "default,critical,long,slack,telegram,mattermost,webhook,retry,celery,grafana";
    CELERY_WORKER_CONCURRENCY = toString cfg.celery.concurrency;
    CELERY_WORKER_MAX_TASKS_PER_CHILD = "100";
    CELERY_WORKER_SHUTDOWN_INTERVAL = "65m";
    CELERY_WORKER_BEAT_ENABLED = "True";

    # Prometheus metrics exporter
    FEATURE_PROMETHEUS_EXPORTER_ENABLED = lib.boolToString (cfg.metrics != null && cfg.metrics.enable);
  } // lib.optionalAttrs cfg.database.usePostgresql {
    DATABASE_TYPE = "postgresql";
    DATABASE_HOST = cfg.database.host;
    DATABASE_PORT = toString cfg.database.port;
    DATABASE_NAME = cfg.database.name;
    DATABASE_USER = cfg.database.user;
  };

in
{
  options.modules.services.grafana-oncall = {
    enable = mkEnableOption "Grafana OnCall incident response platform";

    image = mkOption {
      type = types.str;
      default = "grafana/oncall:v1.16.7@sha256:173a1e6139f30d881f2df58d480990579287e0ee2f3eb279d978a71ea968ae55";
      description = ''
        Grafana OnCall container image with pinned digest.
        Override to upgrade to newer versions.
      '';
      example = "grafana/oncall:v1.17.0@sha256:...";
    };

    user = mkOption {
      type = types.str;
      default = "grafana-oncall";
      description = "System user for Grafana OnCall data ownership";
    };

    uid = mkOption {
      type = types.int;
      default = serviceIds.uid;
      description = "Static UID for the Grafana OnCall user (from lib/service-uids.nix).";
    };

    group = mkOption {
      type = types.str;
      default = "grafana-oncall";
      description = "System group for Grafana OnCall data ownership";
    };

    gid = mkOption {
      type = types.int;
      default = serviceIds.gid;
      description = "Static GID for the Grafana OnCall group (from lib/service-uids.nix).";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/grafana-oncall";
      description = "Directory for Grafana OnCall persistent data";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset path for OnCall data";
      example = "tank/services/grafana-oncall";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to bind the OnCall API server";
    };

    listenPort = mkOption {
      type = types.port;
      default = 8094;
      description = "Port for OnCall API server";
    };

    baseUrl = mkOption {
      type = types.str;
      example = "https://oncall.holthome.net";
      description = ''
        Public URL where OnCall is accessible.
        Used for generating links in notifications.
      '';
    };

    grafanaApiUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:3000";
      description = ''
        Internal URL for Grafana API.
        OnCall uses this to sync users and configure the plugin.
      '';
    };

    # Grafana authentication for plugin sync
    grafana = {
      adminUser = mkOption {
        type = types.str;
        default = "admin";
        description = "Grafana admin username for OnCall plugin authentication";
      };

      adminPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to file containing Grafana admin password.
          Required for OnCall to authenticate with Grafana for user sync.
        '';
        example = "config.sops.secrets.\"grafana/admin-password\".path";
      };
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to environment file containing secrets.
        Should define: SECRET_KEY, MIRAGE_SECRET_KEY, and optionally
        PROMETHEUS_EXPORTER_SECRET for metrics authentication.
        Use sops.templates to generate this file from encrypted secrets.
      '';
      example = "config.sops.templates.\"grafana-oncall-env\".path";
    };

    # Database configuration
    database = {
      type = mkOption {
        type = types.enum [ "sqlite3" "postgresql" ];
        default = "sqlite3";
        description = "Database backend type";
      };

      usePostgresql = mkOption {
        type = types.bool;
        default = false;
        description = "Use PostgreSQL instead of SQLite";
      };

      host = mkOption {
        type = types.str;
        default = "host.containers.internal";
        description = "PostgreSQL host (when using PostgreSQL)";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = mkOption {
        type = types.str;
        default = "oncall";
        description = "Database name";
      };

      user = mkOption {
        type = types.str;
        default = "oncall";
        description = "Database user";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to PostgreSQL password file";
      };

      # For PostgreSQL module integration
      manageDatabase = mkOption {
        type = types.bool;
        default = false;
        description = "Let this module provision the PostgreSQL database";
      };

      localInstance = mkOption {
        type = types.bool;
        default = true;
        description = "Database is on the local host (for dependency ordering)";
      };
    };

    # Bundled Redis configuration
    redis = {
      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Internal Redis port (not exposed externally)";
      };

      image = mkOption {
        type = types.str;
        default = "redis:7.4-alpine";
        description = "Redis container image";
      };
    };

    # Celery worker configuration
    celery = {
      concurrency = mkOption {
        type = types.int;
        default = 1;
        description = "Number of Celery worker processes";
      };
    };

    # Container resources
    resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "1.0";
      };
      description = "Resource limits for OnCall containers";
    };

    healthcheck = mkOption {
      type = types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
      };
      description = "Container healthcheck configuration";
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for OnCall web interface";
    };

    # Standardized metrics collection
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8093;
        path = "/metrics/";
        labels = {
          service_type = "incident-response";
          exporter = "grafana-oncall";
          function = "alerting";
        };
      };
      description = "Prometheus metrics collection configuration";
    };



    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "${engineServiceName}.service";
        labels = {
          service = serviceName;
          service_type = "incident-response";
        };
      };
      description = "Log shipping configuration";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        tags = [ "oncall" "incident-response" "grafana" ];
      };
      description = "Backup configuration";
    };

    # Preseed for disaster recovery
    preseed = {
      enable = mkEnableOption "automatic data restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for restore";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Ordered list of restore methods to attempt";
      };
    };

    # Standardized notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "monitoring-alerts" ];
        };
        customMessages = {
          failure = "Grafana OnCall incident platform failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for service events";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.environmentFile != null;
          message = "modules.services.grafana-oncall.environmentFile must be set (use sops.templates to generate from encrypted secrets)";
        }
        {
          assertion = cfg.database.usePostgresql -> cfg.database.passwordFile != null;
          message = "PostgreSQL mode requires database.passwordFile to be set";
        }
      ];

      # Create system user/group with static UID/GID for container volume permissions
      users.users.${cfg.user} = {
        isSystemUser = true;
        uid = cfg.uid;
        group = cfg.group;
        home = cfg.dataDir;
        description = "Grafana OnCall service user";
      };
      users.groups.${cfg.group} = {
        gid = cfg.gid;
      };

      # ZFS dataset configuration
      modules.storage.datasets.services.grafana-oncall = mkIf (datasetPath != null) {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Directory setup for data persistence
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/data 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/redis 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/celery 0750 ${cfg.user} ${cfg.group} - -"
      ];

      # Create dedicated Podman network for inter-container communication
      modules.virtualization.podman.networks.${networkName} = {
        driver = "bridge";
      };

      # Redis container (broker)
      virtualisation.oci-containers.containers."${serviceName}-redis" = {
        image = cfg.redis.image;
        autoStart = true;

        # Use static UID:GID since container doesn't have access to host passwd
        user = "${toString cfg.uid}:${toString cfg.gid}";

        extraOptions = [
          "--network=${networkName}"
          "--memory=256m"
          "--cpus=0.5"
          "--health-cmd=redis-cli ping"
          "--health-interval=10s"
          "--health-timeout=5s"
          "--health-retries=5"
        ];

        volumes = [
          "${cfg.dataDir}/redis:/data"
        ];

        cmd = [
          "redis-server"
          "--port"
          (toString cfg.redis.port)
          "--bind"
          "0.0.0.0" # Listen on all interfaces within container network
          "--save"
          "60"
          "1"
          "--appendonly"
          "yes"
        ];
      };

      # Database migration container (runs once)
      virtualisation.oci-containers.containers."${serviceName}-migration" = {
        image = cfg.image;
        autoStart = false; # Started by systemd dependency
        # Use static UID:GID since container doesn't have access to host passwd
        user = "${toString cfg.uid}:${toString cfg.gid}";

        environment = oncallEnvironment // {
          # Migration doesn't need metrics
          FEATURE_PROMETHEUS_EXPORTER_ENABLED = "False";
        };

        environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optionals (cfg.database.usePostgresql && cfg.database.passwordFile != null) [
          cfg.database.passwordFile
        ];

        volumes = [
          "${cfg.dataDir}/data:/var/lib/oncall"
        ];

        extraOptions = [
          "--network=${networkName}"
          "--memory=512m"
          "--cpus=1.0"
        ];

        cmd = [ "python" "manage.py" "migrate" "--noinput" ];
      };

      # Engine container (main API server)
      virtualisation.oci-containers.containers."${serviceName}-engine" = {
        image = cfg.image;
        autoStart = true;
        # Use static UID:GID since container doesn't have access to host passwd
        user = "${toString cfg.uid}:${toString cfg.gid}";

        dependsOn = [
          "${serviceName}-redis"
        ];

        environment = oncallEnvironment;

        environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optionals (cfg.database.usePostgresql && cfg.database.passwordFile != null) [
          cfg.database.passwordFile
        ];

        volumes = [
          "${cfg.dataDir}/data:/var/lib/oncall"
        ];

        # Map container port 8080 to host listenPort
        ports = [
          "${cfg.listenAddress}:${toString cfg.listenPort}:8080"
        ];

        extraOptions = [
          "--network=${networkName}"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          "--health-cmd=wget --spider -q http://127.0.0.1:8080/health/ || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
        ] ++ lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--cpus=${cfg.resources.cpus}"
        ];

        # Use default command (uwsgi.ini binds to 0.0.0.0:8080 inside container)
      };

      # Celery worker container
      virtualisation.oci-containers.containers."${serviceName}-celery" = {
        image = cfg.image;
        autoStart = true;
        # Use static UID:GID since container doesn't have access to host passwd
        user = "${toString cfg.uid}:${toString cfg.gid}";

        dependsOn = [
          "${serviceName}-redis"
        ];

        environment = oncallEnvironment;

        environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optionals (cfg.database.usePostgresql && cfg.database.passwordFile != null) [
          cfg.database.passwordFile
        ];

        volumes = [
          "${cfg.dataDir}/data:/var/lib/oncall"
          # Mount writable directory for celerybeat-schedule
          # Celery Beat writes its schedule database to the working directory
          # but /etc/app is read-only, so we use a separate writable location
          "${cfg.dataDir}/celery:/var/lib/oncall/celery"
        ];

        extraOptions = [
          "--network=${networkName}"
        ] ++ lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--cpus=${cfg.resources.cpus}"
        ];

        # Change working directory to writable location for celerybeat-schedule
        # and add /etc/app to PYTHONPATH so celery can find the engine module
        cmd = [ "sh" "-c" "export PYTHONPATH=/etc/app:$PYTHONPATH && cd /var/lib/oncall/celery && /etc/app/celery_with_exporter.sh" ];
      };

      # Network service name for dependencies
      # Note: This is the systemd unit created by modules.virtualization.podman.networks
      # The naming convention is: podman-network-<networkName>.service

      # Systemd service ordering - add network dependencies
      systemd.services."${redisServiceName}" = {
        requires = [ "podman-network-${networkName}.service" ];
        after = [ "podman-network-${networkName}.service" ];
      };

      systemd.services."${engineServiceName}" = {
        requires = [ "podman-network-${networkName}.service" ];
        after = [
          "podman-network-${networkName}.service"
          "${redisServiceName}.service"
          "${migrationServiceName}.service"
        ] ++ lib.optionals cfg.preseed.enable [
          "${serviceName}-preseed.service"
        ] ++ lib.optionals (cfg.database.usePostgresql && cfg.database.localInstance) [
          "postgresql.service"
        ];
        wants = [
          "${redisServiceName}.service"
        ];
      };

      systemd.services."${celeryServiceName}" = {
        requires = [ "podman-network-${networkName}.service" ];
        after = [
          "podman-network-${networkName}.service"
          "${engineServiceName}.service"
        ];
        wants = [
          "${engineServiceName}.service"
        ];
      };

      # Run migration before engine starts
      systemd.services."${migrationServiceName}" = {
        requires = [ "podman-network-${networkName}.service" ];
        after = [
          "podman-network-${networkName}.service"
          "${redisServiceName}.service"
        ] ++ lib.optionals (cfg.database.usePostgresql && cfg.database.localInstance) [
          "postgresql.service"
        ];
        wants = [
          "${redisServiceName}.service"
        ];
        wantedBy = [ "${engineServiceName}.service" ];
        before = [ "${engineServiceName}.service" ];
        serviceConfig = {
          Type = lib.mkForce "oneshot";
          Restart = lib.mkForce "no";
          RemainAfterExit = lib.mkForce true;
        };
      };

      # Reverse proxy configuration
      modules.services.caddy.virtualHosts.grafana-oncall = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          host = cfg.reverseProxy.backend.host or cfg.listenAddress;
          port = cfg.reverseProxy.backend.port or cfg.listenPort;
        };
        caddySecurity = cfg.reverseProxy.caddySecurity or null;
        extraConfig = cfg.reverseProxy.extraConfig or null;
      };

      # NOTE: Homepage and Gatus contributions should be set in host config,
      # not auto-generated here. See hosts/forge/README.md for contribution pattern.

      # Backup job registration
      modules.backup.restic.jobs.${serviceName} = mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        repository = cfg.backup.repository;
        frequency = cfg.backup.frequency or "daily";
        retention = cfg.backup.retention or { };
        paths = [ cfg.dataDir ];
        excludePatterns = (cfg.backup.excludePatterns or [ ]) ++ [
          "redis/dump.rdb" # Redis can be recreated
          "*.log"
        ];
        useSnapshots = cfg.backup.useSnapshots or true;
        zfsDataset = cfg.backup.zfsDataset or datasetPath;
        tags = cfg.backup.tags or [ serviceName ];
      };
    })

    # Preseed service for disaster recovery (separate mkMerge block)
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "${engineServiceName}.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = (config.modules.notifications or { }).enable or false;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
