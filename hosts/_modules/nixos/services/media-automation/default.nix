{ config, lib, ... }:

let
  cfg = config.modules.services.media-automation;

  # Helper to check if any instance of a service type is enabled
  anyEnabled = instances: lib.any (inst: inst.enable) (lib.attrValues instances);

  # Helper to build dependency structure for a service instance
  mkServiceDependencies = serviceType: _instanceName:
    let
      # For radarr and sonarr: wire to all enabled prowlarr instances
      prowlarrDeps = lib.optionalAttrs
        (lib.elem serviceType [ "radarr" "sonarr" ] && anyEnabled cfg.prowlarr)
        {
          prowlarr = lib.mapAttrs
            (_: inst: {
              inherit (inst) host port;
              apiKeyFile = inst.apiKeyFile;
            })
            (lib.filterAttrs (_: inst: inst.enable) cfg.prowlarr);
        };

      # For bazarr: wire to all enabled sonarr and radarr instances
      arrDeps = lib.optionalAttrs (serviceType == "bazarr") {
        sonarr = lib.mapAttrs
          (_: inst: {
            inherit (inst) host port;
            apiKeyFile = inst.apiKeyFile;
          })
          (lib.filterAttrs (_: inst: inst.enable) cfg.sonarr);

        radarr = lib.mapAttrs
          (_: inst: {
            inherit (inst) host port;
            apiKeyFile = inst.apiKeyFile;
          })
          (lib.filterAttrs (_: inst: inst.enable) cfg.radarr);
      };
    in
    prowlarrDeps // arrDeps;

  # Generate configuration for a single service instance
  # This creates config that feeds into the existing per-service modules
  mkInstanceConfig = serviceType: instanceName: instanceCfg:
    let
      serviceDeps = mkServiceDependencies serviceType instanceName;
    in
    {
      modules.services.${serviceType} = {
        enable = true;
        inherit (instanceCfg)
          dataDir
          user
          group
          openFirewall;

        container = {
          inherit (instanceCfg.container)
            image
            imageFile
            environmentFiles
            extraOptions;
        };

        # Auto-wire dependencies to other *arr services
        dependencies = serviceDeps;

        caddy = lib.mkIf instanceCfg.caddy.enable {
          enable = true;
          inherit (instanceCfg.caddy) host subdomain;
        };

        monitoring = lib.mkIf (cfg.monitoring.enable && instanceCfg.monitoring.enable) {
          enable = true;
          inherit (instanceCfg.monitoring)
            enablePrometheus
            enableLoki
            promtail;
        };

        backup = lib.mkIf (cfg.backup.enable && instanceCfg.backup.enable) {
          enable = true;
          inherit (instanceCfg.backup)
            paths
            excludePatterns
            preBackupScript
            checkAfterBackup;
        };

        healthcheck = lib.mkIf instanceCfg.healthcheck.enable {
          enable = true;
          inherit (instanceCfg.healthcheck)
            http
            tcp
            interval
            timeout
            startPeriod
            retries;
        };
      };
    };

  # Options for a single service instance (used by all service types)
  instanceOptions = serviceType: {
    enable = lib.mkEnableOption "this ${serviceType} instance";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/${serviceType}";
      description = "Directory for ${serviceType} data";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = cfg.sharedUser;
      description = "User to run ${serviceType} as (defaults to shared user)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.sharedGroup;
      description = "Group to run ${serviceType} under (defaults to shared media group)";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open firewall ports for this instance";
    };

    container = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/home-operations/${serviceType}:latest";
        description = "Container image to use";
      };

      imageFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to container image archive (alternative to pulling)";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Environment files for container (e.g., SOPS secrets)";
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional container runtime options";
      };
    };

    # Internal port the service listens on
    port = lib.mkOption {
      type = lib.types.port;
      default =
        if serviceType == "prowlarr" then 9696
        else if serviceType == "radarr" then 7878
        else if serviceType == "sonarr" then 8989
        else if serviceType == "bazarr" then 6767
        else if serviceType == "lidarr" then 8686
        else if serviceType == "readarr" then 8787
        else 8080;
      description = "Port the service listens on";
    };

    # Hostname for inter-service communication
    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Hostname for API access (usually localhost)";
    };

    # API key file path (for services that need API keys)
    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing API key for this service";
    };

    caddy = {
      enable = lib.mkEnableOption "${serviceType} Caddy reverse proxy";

      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "${serviceType}";
        description = "Subdomain for this instance";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = config.networking.domain or "example.com";
        description = "Domain to use for Caddy virtual host";
      };
    };

    monitoring = {
      enable = lib.mkEnableOption "${serviceType} monitoring";

      enablePrometheus = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Prometheus metrics scraping";
      };

      enableLoki = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Loki log aggregation";
      };

      promtail = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Promtail configuration for log collection";
      };
    };

    backup = {
      enable = lib.mkEnableOption "${serviceType} backups";

      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "\${cfg.dataDir}" ];
        description = "Paths to back up";
      };

      excludePatterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Patterns to exclude from backup";
      };

      preBackupScript = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Script to run before backup";
      };

      checkAfterBackup = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to verify backup after completion";
      };
    };

    healthcheck = {
      enable = lib.mkEnableOption "${serviceType} health checks";

      http = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "http://127.0.0.1:\${toString cfg.port}/ping";
        description = "HTTP endpoint for health check";
      };

      tcp = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "TCP port for health check";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Health check interval";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Health check timeout";
      };

      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Initial grace period for health checks";
      };

      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries before marking unhealthy";
      };
    };
  };

in
{
  options.modules.services.media-automation = {
    enable = lib.mkEnableOption "media automation services (*arr stack)";

    # Shared configuration for all services
    sharedUser = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Shared user for media automation services (if not overridden per-instance)";
    };

    sharedGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Shared group for media automation services (GID 65537)";
    };

    # Global monitoring toggle
    monitoring = {
      enable = lib.mkEnableOption "monitoring for all media automation services";
    };

    # Global backup toggle
    backup = {
      enable = lib.mkEnableOption "backups for all media automation services";
    };

    # Individual service types with multiple instance support
    prowlarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "prowlarr";
      });
      default = { };
      description = "Prowlarr indexer manager instances";
    };

    radarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "radarr";
      });
      default = { };
      description = "Radarr movie manager instances";
    };

    sonarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "sonarr";
      });
      default = { };
      description = "Sonarr TV show manager instances";
    };

    bazarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "bazarr";
      });
      default = { };
      description = "Bazarr subtitle manager instances";
    };

    lidarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "lidarr";
      });
      default = { };
      description = "Lidarr music manager instances";
    };

    readarr = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions "readarr";
      });
      default = { };
      description = "Readarr book/audiobook manager instances";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Generate service configurations for all enabled instances
    (lib.mkMerge (
      lib.flatten (
        lib.mapAttrsToList
          (serviceType: instances:
            lib.mapAttrsToList
              (instanceName: instanceCfg:
                lib.mkIf instanceCfg.enable (mkInstanceConfig serviceType instanceName instanceCfg)
              )
              instances
          )
          {
            inherit (cfg) prowlarr radarr sonarr bazarr lidarr readarr;
          }
      )
    ))

    # Ensure shared group exists
    {
      users.groups.${cfg.sharedGroup} = lib.mkIf (cfg.sharedGroup != "root") {
        gid = lib.mkDefault 65537; # Shared media group (993 was taken by alertmanager)
      };
    }
  ]);
}
