{
  lib,
  config,
  podmanLib,
  ...
}:
let
  cfg = config.modules.services.sonarr;
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  sonarrPort = 8989;
in
{
  options.modules.services.sonarr = {
    enable = lib.mkEnableOption "sonarr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sonarr";
      description = "Path to Sonarr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "568";
      description = "User ID to own the data directory (sonarr:sonarr in container)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "568";
      description = "Group ID to own the data directory";
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/media";
      description = "Path to media library (typically NFS mount)";
    };

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group with permissions to the media library, for NFS access.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "512m";
            description = "Memory limit for the container";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "2.0";
            description = "CPU limit for the container";
          };
        };
      });
      default = { memory = "512m"; cpus = "2.0"; };
      description = "Resource limits for the container";
    };

    healthcheck = {
      enable = lib.mkEnableOption "container health check";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "1m";
        description = "Frequency of health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for each health check.";
      };
      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking as unhealthy.";
      };
    };

    backup = {
      enable = lib.mkEnableOption "backup for Sonarr data";
      repository = lib.mkOption {
        type = lib.types.str;
        default = "nas-primary";
        description = "Name of the Restic repository to use for backups.";
      };
    };

    notifications = {
      enable = lib.mkEnableOption "failure notifications for the Sonarr service";
    };
  };

  config = lib.mkIf cfg.enable {
    # Declare dataset requirements for per-service ZFS isolation
    # This integrates with the storage.datasets module to automatically
    # create tank/services/sonarr with appropriate ZFS properties
    modules.storage.datasets.services.sonarr = {
      mountpoint = cfg.dataDir;
      recordsize = "16K";  # Optimal for SQLite databases
      compression = "zstd";  # Better compression for text/config files
      properties = {
        "com.sun:auto-snapshot" = "true";  # Enable automatic snapshots
      };
      # Ownership matches the container user/group
      owner = "sonarr";
      group = "sonarr";
      mode = "0700";  # Restrictive permissions
    };

    # Create local users to match container UIDs
    # This ensures proper file ownership on the host
    users.users.sonarr = {
      uid = lib.mkDefault (lib.toInt cfg.user);
      group = "sonarr";
      isSystemUser = true;
      description = "Sonarr service user";
      extraGroups = [ cfg.mediaGroup ]; # Add to media group for NFS access
    };

    users.groups.sonarr = {
      gid = lib.mkDefault (lib.toInt cfg.group);
    };

    # Ensure the media group exists
    users.groups.${cfg.mediaGroup} = { };

    # Sonarr container configuration
    virtualisation.oci-containers.containers.sonarr = podmanLib.mkContainer "sonarr" {
      image = "lscr.io/linuxserver/sonarr:latest";
      environment = {
        PUID = cfg.user;
        PGID = cfg.group;
        TZ = cfg.timezone;
      };
      volumes = [
        "${cfg.dataDir}:/config:rw"
        "${cfg.mediaDir}:/media:rw"
      ];
      ports = [
        "${toString sonarrPort}:8989"
      ];
      resources = cfg.resources;
      extraOptions = [
        "--pull=newer"  # Automatically pull newer images
      ] ++ lib.optionals cfg.healthcheck.enable [
        # Container-native health check using Podman health check options
        "--health-cmd=curl -f http://localhost:8989/login || exit 1"
        "--health-interval=${cfg.healthcheck.interval}"
        "--health-timeout=${cfg.healthcheck.timeout}"
        "--health-retries=${toString cfg.healthcheck.retries}"
      ];
    };

    # Add failure notifications via systemd
    systemd.services."${config.virtualisation.oci-containers.backend}-sonarr".unitConfig = lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
      OnFailure = [ "notify@sonarr-failure:%n.service" ];
    };

    # Register notification template
    modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications.enable) {
      "sonarr-failure" = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Sonarr</font></b>'';
        body = lib.mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Sonarr service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
    };

    # Integrate with backup system
    # Reuses existing backup infrastructure (Restic, notifications, etc.)
    modules.backup.restic.jobs.sonarr = lib.mkIf (config.modules.backup.enable && cfg.backup.enable) {
      enable = true;
      paths = [ cfg.dataDir ];
      excludePatterns = [
        "**/.cache"
        "**/cache"
        "**/*.tmp"
        "**/logs/*.txt"  # Exclude verbose logs
      ];
      repository = cfg.backup.repository;
      tags = [ "sonarr" "media" "database" ];
    };

    # Optional: Open firewall for Sonarr web UI
    # Disabled by default since forge has firewall.enable = false
    # networking.firewall.allowedTCPPorts = [ sonarrPort ];
  };
}
