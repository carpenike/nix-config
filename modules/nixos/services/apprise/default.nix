# modules/nixos/services/apprise/default.nix
#
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
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "apprise";
  description = "Apprise API notification gateway";

  spec = {
    # Core service configuration
    # Note: Container version (1.3.0) differs from Python apprise package
    # version (1.9.5) - the apprise-api container is versioned independently.
    port = 8000;
    image = "docker.io/caronc/apprise:v1.5.1@sha256:1871ed736799f6320d5061b72a60507f62c8747026e830175dc4b9f8adbf78dd";
    operationalProfile = "infrastructure";
    displayName = "Apprise";
    function = "notification_gateway";

    # Health check via the /status endpoint; Apprise starts quickly.
    healthCommand = "curl -sf http://localhost:8000/status || exit 1";
    startPeriod = "10s";

    # ZFS tuning - small config files
    zfsRecordSize = "16K";
    zfsCompression = "lz4";

    # Lightweight API gateway
    resources = {
      memory = "256m";
      memoryReservation = "128m";
      cpus = "0.5";
    };

    environment = { cfg, config, ... }: {
      PUID = cfg.user;
      PGID = toString config.users.groups.${cfg.group}.gid;
      APPRISE_STATEFUL_MODE = cfg.statefulMode;
      APPRISE_WORKER_COUNT = toString cfg.workerCount;
      APPRISE_ADMIN = if cfg.enableAdmin then "y" else "n";
    } // cfg.extraEnvironment;

    # Apprise uses split config/attach/plugin mounts instead of a single
    # dataDir:/config mount.
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}/config:/config:rw"
      "${cfg.dataDir}/attach:/attach:rw"
      "${cfg.dataDir}/plugin:/plugin:ro"
    ];

    # Container hardening - Apprise runs read-only with a tmpfs scratch space
    extraOptions = _: [
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges:true"
      "--read-only"
    ];
  };

  extraOptions = {
    statefulMode = lib.mkOption {
      type = lib.types.enum [ "disabled" "simple" "hash" ];
      default = "simple";
      description = ''
        Stateful mode for Apprise:
        - disabled: No persistent configuration, URLs must be provided with each request
        - simple: URLs stored by simple key name (e.g., "default", "alerts")
        - hash: URLs stored by hash for more security
      '';
    };

    workerCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of worker processes for handling requests";
    };

    enableAdmin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the web-based admin interface for managing notification URLs";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables to pass to the container";
    };

    # Apprise exposes no Prometheus metrics endpoint - keep metrics opt-in
    # (overrides the factory default of enabled).
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (Apprise has no native metrics)";
    };

    # Failure notifications for the notification gateway itself are opt-in:
    # if Apprise is down, its own failure notification cannot be delivered
    # through it anyway.
    notifications = lib.mkOption {
      type = lib.types.nullOr mylib.types.notificationSubmodule;
      default = null;
      description = "Notification configuration for Apprise service events";
    };
  };

  extraConfig = cfg: {
    # Only bind to localhost - external access goes through the reverse proxy.
    virtualisation.oci-containers.containers.apprise.ports = lib.mkForce [
      "127.0.0.1:${toString cfg.port}:8000"
    ];

    # Subdirectory permissions inside the dataset
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/attach 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/plugin 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services."${config.virtualisation.oci-containers.backend}-apprise" = {
      # Create subdirectories before container starts.
      # tmpfiles.rules are processed at boot, but may not run before this service.
      preStart = lib.mkAfter ''
        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/config
        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/attach
        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/plugin
      '';
      serviceConfig.RestartSec = "10s";
    };
  };
}
