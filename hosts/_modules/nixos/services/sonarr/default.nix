{
  pkgs,
  lib,
  config,
  podmanLib,
  ...
}:
let
  cfg = config.modules.services.sonarr;
  storageCfg = config.modules.storage.datasets;
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
    };

    users.groups.sonarr = {
      gid = lib.mkDefault (lib.toInt cfg.group);
    };

    # Ensure data directory exists with proper permissions
    # tmpfiles runs early in boot, before the service starts
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 sonarr sonarr - -"
    ];

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
      ];
    };

    # Integrate with backup system
    # Reuses existing backup infrastructure (Restic, notifications, etc.)
    modules.backup.restic.jobs.sonarr = lib.mkIf config.modules.backup.enable {
      enable = true;
      paths = [ cfg.dataDir ];
      excludePatterns = [
        "**/.cache"
        "**/cache"
        "**/*.tmp"
        "**/logs/*.txt"  # Exclude verbose logs
      ];
      repository = "nas-primary";
      tags = [ "sonarr" "media" "database" ];
    };

    # Optional: Open firewall for Sonarr web UI
    # Disabled by default since forge has firewall.enable = false
    # networking.firewall.allowedTCPPorts = [ sonarrPort ];
  };
}
