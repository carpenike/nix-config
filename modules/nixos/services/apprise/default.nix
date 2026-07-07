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
# Factory-based implementation (mylib.mkContainerService).
#
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
    description = "Apprise API notification gateway";
    port = 8000;
    # Note: Container version (1.3.0) differs from Python apprise package version
    # (1.9.5). The apprise-api container is versioned independently.
    image = "docker.io/caronc/apprise:1.3.0";
    category = "infrastructure";
    displayName = "Apprise";
    function = "notification_gateway";

    # Runs as the apprise service user via --user (factory adds --cap-drop=ALL
    # and no-new-privileges for non-root containers)
    runAsRoot = false;

    healthEndpoint = "/status";
    startPeriod = "10s";

    # Small config files
    zfsRecordSize = "16K";
    zfsCompression = "lz4";
    zfsProperties = {
      "com.sun:auto-snapshot" = "true";
    };

    # Uses per-purpose subdirectory mounts instead of the default /config mount
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}/config:/config:rw"
      "${cfg.dataDir}/attach:/attach:rw"
      "${cfg.dataDir}/plugin:/plugin:ro"
    ];

    resources = {
      memory = "256m";
      memoryReservation = "128m";
      cpus = "0.5";
    };

    environment = { cfg, config, ... }: {
      # PUID/PGID are inert under --user but kept for image parity
      PUID = cfg.user;
      PGID = toString config.users.groups.${cfg.group}.gid;
      APPRISE_STATEFUL_MODE = cfg.statefulMode;
      APPRISE_WORKER_COUNT = toString cfg.workerCount;
      APPRISE_ADMIN = if cfg.enableAdmin then "y" else "n";
    } // cfg.extraEnvironment;

    # Read-only root filesystem with a writable tmpfs for scratch space
    extraOptions = _cfg: [
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m"
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

    # Preserve the pre-factory default (host timezone instead of a fixed zone)
    timezone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone for the Apprise container";
    };

    # Apprise IS the notification gateway - routing its own failure through
    # itself is not useful, and the pre-factory module wired no notifications.
    notifications = lib.mkOption {
      type = lib.types.nullOr mylib.types.notificationSubmodule;
      default = null;
      description = "Notification configuration. Disabled by default for the notification gateway itself.";
    };
  };

  extraConfig = cfg: {
    # Directory permissions for the per-purpose subdirectories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/attach 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/plugin 0750 ${cfg.user} ${cfg.group} - -"
    ];

    # Create subdirectories before container starts.
    # tmpfiles.rules are processed at boot, but may not run before this service.
    systemd.services."${config.virtualisation.oci-containers.backend}-apprise".preStart = lib.mkAfter ''
      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/config
      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/attach
      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/plugin
    '';
  };
}
