# lib/service-factory.nix
#
# Helm-like factory functions for creating standardized service modules.
# This dramatically reduces boilerplate by providing a single function that
# generates complete NixOS module definitions from a concise service spec.
#
# PHILOSOPHY:
# - Similar to Helm's values.yaml + _helpers.tpl pattern
# - Services define WHAT they are (spec), factory handles HOW to configure
# - Shared patterns (reverseProxy, backup, metrics) are automatic
# - Service-specific overrides are still possible
#
# USAGE:
#   # In modules/nixos/services/sonarr/default.nix:
#   { lib, mylib, pkgs, config, podmanLib, ... }:
#   mylib.mkContainerService {
#     inherit lib mylib pkgs config podmanLib;
#     name = "sonarr";
#     description = "TV series collection manager";
#
#     # Service-specific configuration
#     spec = {
#       port = 8989;
#       image = "ghcr.io/home-operations/sonarr:latest";
#       category = "media";
#       healthEndpoint = "/ping";
#
#       # Service-specific environment variables
#       environment = cfg: {
#         SONARR__AUTH__METHOD = if cfg.usesExternalAuth then "External" else "None";
#       };
#
#       # Service-specific volumes beyond dataDir
#       volumes = cfg: [
#         "${cfg.mediaDir}:/data:rw"
#       ];
#
#       # Service-specific container options
#       extraOptions = cfg: [
#         "--group-add=${toString config.users.groups.${cfg.mediaGroup}.gid}"
#       ];
#     };
#
#     # Optional: additional options beyond the standard set
#     extraOptions = {
#       apiKeyFile = lib.mkOption { ... };
#     };
#
#     # Optional: additional config beyond the standard set
#     extraConfig = cfg: { ... };
#   }
#
# WHAT THE FACTORY PROVIDES:
# - Standard options: enable, dataDir, user, group, image, timezone, resources,
#   healthcheck, reverseProxy, metrics, logging, backup, notifications, preseed
# - For media services: mediaDir, nfsMountDependency, mediaGroup, podmanNetwork
# - Standard config: Caddy registration, ZFS dataset, user creation, systemd deps

{ lib }:

let
  # Service categories with default configurations
  categoryDefaults = {
    media = {
      serviceType = "media_management";
      alertChannel = "media-alerts";
      hasNfsMount = true;
      defaultMediaGroup = "media";
      tags = [ "media" ];
    };
    productivity = {
      serviceType = "productivity";
      alertChannel = "system-alerts";
      hasNfsMount = false;
      defaultMediaGroup = null;
      tags = [ "productivity" ];
    };
    infrastructure = {
      serviceType = "infrastructure";
      alertChannel = "system-alerts";
      hasNfsMount = false;
      defaultMediaGroup = null;
      tags = [ "infrastructure" ];
    };
    home-automation = {
      serviceType = "home_automation";
      alertChannel = "home-alerts";
      hasNfsMount = false;
      defaultMediaGroup = null;
      tags = [ "home-automation" ];
    };
    downloads = {
      serviceType = "downloads";
      alertChannel = "media-alerts";
      hasNfsMount = true;
      defaultMediaGroup = "media";
      tags = [ "downloads" ];
    };
    monitoring = {
      serviceType = "observability";
      alertChannel = "system-alerts";
      hasNfsMount = false;
      defaultMediaGroup = null;
      tags = [ "monitoring" ];
    };
    ai = {
      serviceType = "ai";
      alertChannel = "system-alerts";
      hasNfsMount = false;
      defaultMediaGroup = null;
      tags = [ "ai" ];
    };
  };

  # Standard options that every container service gets
  mkStandardOptions = { lib, sharedTypes, serviceIds, spec, name, extraOptions ? { } }:
    let
      category = categoryDefaults.${spec.category or "productivity"};
    in
    {
      enable = lib.mkEnableOption "${spec.description or name}";

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/${name}";
        description = "Path to ${name} data directory";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = spec.port;
        description = "Port for ${name} web interface";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = toString serviceIds.uid;
        description = "User ID under which ${name} runs (from lib/service-uids.nix)";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = if category.hasNfsMount then category.defaultMediaGroup else name;
        description = "Group under which ${name} runs";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = spec.image;
        description = "Container image for ${name}. Pin to specific version with digest for immutability.";
        example = "${spec.image}@sha256:...";
      };

      timezone = lib.mkOption {
        type = lib.types.str;
        default = "America/New_York";
        description = "Timezone for the container";
      };

      resources = lib.mkOption {
        type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
        default = spec.resources or {
          memory = "512M";
          memoryReservation = "256M";
          cpus = "1.0";
        };
        description = "Resource limits for the container";
      };

      healthcheck = lib.mkOption {
        type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
        default = {
          enable = true;
          interval = "30s";
          timeout = "10s";
          retries = 3;
          startPeriod = spec.startPeriod or "120s";
          onFailure = "kill";
        };
        description = "Container healthcheck configuration";
      };

      reverseProxy = lib.mkOption {
        type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
        default = null;
        description = "Reverse proxy configuration for ${name} web interface";
      };

      metrics = lib.mkOption {
        type = lib.types.nullOr sharedTypes.metricsSubmodule;
        default = {
          enable = true;
          port = spec.port;
          path = spec.metricsPath or "/metrics";
          labels = {
            service_type = category.serviceType;
            exporter = name;
            function = spec.function or name;
          };
        };
        description = "Prometheus metrics collection configuration";
      };

      logging = lib.mkOption {
        type = lib.types.nullOr sharedTypes.loggingSubmodule;
        default = {
          enable = true;
          journalUnit = "podman-${name}.service";
          labels = {
            service = name;
            service_type = category.serviceType;
          };
        };
        description = "Log shipping configuration";
      };

      backup = lib.mkOption {
        type = lib.types.nullOr sharedTypes.backupSubmodule;
        default = {
          enable = true;
          repository = "nas-primary";
          frequency = "daily";
          tags = category.tags ++ [ name "config" ];
          useSnapshots = spec.useZfsSnapshots or true;
          zfsDataset = "tank/services/${name}";
          excludePatterns = [
            "**/*.log"
            "**/cache/**"
            "**/logs/**"
          ] ++ (spec.backupExcludePatterns or [ ]);
        };
        description = "Backup configuration";
      };

      notifications = lib.mkOption {
        type = lib.types.nullOr sharedTypes.notificationSubmodule;
        default = {
          enable = true;
          channels = {
            onFailure = [ category.alertChannel ];
          };
          customMessages = {
            failure = "${spec.displayName or name} service failed on \${config.networking.hostName}";
          };
        };
        description = "Notification configuration";
      };

      preseed = {
        enable = lib.mkEnableOption "automatic data restore before service start";
        repositoryUrl = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Restic repository URL for restore operations";
        };
        passwordFile = lib.mkOption {
          type = lib.types.path;
          default = "/run/secrets/restic-password";
          description = "Path to Restic password file";
        };
        environmentFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Optional environment file for Restic";
        };
        restoreMethods = lib.mkOption {
          type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
          default = [ "syncoid" "local" "restic" ];
          description = "Order of restore methods to attempt";
        };
      };

      # Media/download service options - always declared, conditionally used
      # This ensures consistent option interface regardless of service category
      mediaDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = if category.hasNfsMount then "/mnt/media" else null;
        description = "Path to media library. Only used by media/download services.";
      };

      nfsMountDependency = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the NFS mount to use for media. Only used by media/download services.";
        example = "media";
      };

      mediaGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = category.defaultMediaGroup;
        description = "Group with permissions to the media library";
      };

      podmanNetwork = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Podman network to attach this container to";
        example = "media-services";
      };
    }
    // extraOptions;

  # Standard assertions that every container service gets
  mkStandardAssertions = { cfg, name, nfsMountConfig, category }:
    (lib.optional (category.hasNfsMount && cfg.nfsMountDependency or null != null) {
      assertion = nfsMountConfig != null;
      message = "${name} nfsMountDependency '${cfg.nfsMountDependency}' does not exist in modules.storage.nfsMounts.";
    })
    ++ (lib.optional (cfg.backup != null && cfg.backup.enable) {
      assertion = cfg.backup.repository != null;
      message = "${name} backup.enable requires backup.repository to be set.";
    })
    ++ (lib.optional (cfg.preseed.enable or false) {
      assertion = cfg.preseed.repositoryUrl != "";
      message = "${name} preseed.enable requires preseed.repositoryUrl to be set.";
    });

in
{
  # Main factory function for container services
  mkContainerService =
    { lib
    , mylib
    , pkgs
    , config
    , podmanLib
    , name
    , description ? name
    , spec
    , extraOptions ? { }
    , extraConfig ? _cfg: { }
    }:
    let
      sharedTypes = mylib.types;
      storageHelpers = mylib.storageHelpers pkgs;
      serviceIds = mylib.serviceUids.${name} or { uid = 1000; gid = 1000; };

      # CRITICAL: Validate spec at eval time to catch typos and missing fields
      # Without this, errors like spec.zfsRecordsize (wrong case) would silently
      # fall back to defaults and only fail at deploy time.
      validatedSpec = sharedTypes.validateServiceSpec spec;

      cfg = config.modules.services.${name};
      storageCfg = config.modules.storage;
      notificationsCfg = config.modules.notifications;

      category = categoryDefaults.${validatedSpec.category};
      mainServiceUnit = "${config.virtualisation.oci-containers.backend}-${name}.service";
      datasetPath = "${storageCfg.datasets.parentDataset}/${name}";

      nfsMountName = if category.hasNfsMount then (cfg.nfsMountDependency or null) else null;
      nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };
      replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

      usesExternalAuth =
        cfg.reverseProxy != null
        && cfg.reverseProxy.enable
        && (cfg.reverseProxy.caddySecurity != null && cfg.reverseProxy.caddySecurity.enable);
    in
    {
      options.modules.services.${name} = mkStandardOptions
        {
          inherit lib sharedTypes serviceIds name extraOptions;
          spec = validatedSpec; # Pass validated spec to options
        } // {
        # Debug introspection attribute - helps diagnose factory behavior
        _debug = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          internal = true;
          description = "Debug information about factory-generated values";
        };
      };

      config = lib.mkMerge [
        (lib.mkIf cfg.enable {
          # Service-specific config - grouped to avoid duplicate attribute keys
          modules.services.${name} = {
            # Populate debug attribute for introspection
            _debug = {
              factoryVersion = "1.0";
              serviceName = name;
              category = {
                name = validatedSpec.category;
                hasNfsMount = category.hasNfsMount;
                defaultMediaGroup = category.defaultMediaGroup;
                tags = category.tags;
              };
              validatedSpec = {
                port = validatedSpec.port;
                image = validatedSpec.image;
                zfsRecordSize = validatedSpec.zfsRecordSize;
                zfsCompression = validatedSpec.zfsCompression;
                useZfsSnapshots = validatedSpec.useZfsSnapshots;
                healthEndpoint = validatedSpec.healthEndpoint or null;
                metricsPath = validatedSpec.metricsPath;
                containerPort = validatedSpec.containerPort or null;
              };
              derived = {
                serviceIds = serviceIds;
                datasetPath = datasetPath;
                mainServiceUnit = mainServiceUnit;
                usesExternalAuth = usesExternalAuth;
                nfsMountConfigPresent = nfsMountConfig != null;
                replicationConfigPresent = replicationConfig != null;
              };
            };

            # Auto-set mediaDir from NFS mount
            mediaDir = lib.mkIf (nfsMountConfig != null)
              (lib.mkDefault nfsMountConfig.localPath);
          };

          assertions = mkStandardAssertions { inherit cfg name nfsMountConfig category; };

          # Caddy reverse proxy registration
          modules.services.caddy.virtualHosts.${name} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
            enable = true;
            hostName = cfg.reverseProxy.hostName;
            backend = {
              scheme = validatedSpec.backendScheme or "http";
              host = "127.0.0.1";
              port = cfg.port;
            };
            auth = cfg.reverseProxy.auth;
            caddySecurity = cfg.reverseProxy.caddySecurity;
            security = cfg.reverseProxy.security;
            extraConfig = cfg.reverseProxy.extraConfig;
          };

          # ZFS dataset - use mkDefault so hosts can override
          modules.storage.datasets.services.${name} = {
            mountpoint = lib.mkDefault cfg.dataDir;
            recordsize = lib.mkDefault validatedSpec.zfsRecordSize;
            compression = lib.mkDefault (validatedSpec.zfsCompression or "zstd");
            properties = lib.mkDefault ({
              "com.sun:auto-snapshot" = "true";
            } // (validatedSpec.zfsProperties or { }));
            owner = lib.mkDefault cfg.user;
            group = lib.mkDefault cfg.group;
            mode = lib.mkDefault "0750";
          };

          # System user - use mkDefault for all properties
          users.users.${name} = {
            uid = lib.mkDefault (lib.toInt cfg.user);
            group = lib.mkDefault cfg.group;
            isSystemUser = lib.mkDefault true;
            description = lib.mkDefault "${description} service user";
            extraGroups = lib.mkDefault (lib.optional (nfsMountName != null) (cfg.mediaGroup or "media"));
          };

          # System group - only create if it matches service name (not media/media)
          users.groups.${name} = lib.mkIf (cfg.group == name) {
            gid = lib.mkDefault serviceIds.gid;
          };

          # Container
          virtualisation.oci-containers.containers.${name} = podmanLib.mkContainer name ({
            image = cfg.image;
            environment = {
              PUID = cfg.user;
              PGID = toString config.users.groups.${cfg.group}.gid;
              TZ = cfg.timezone;
              UMASK = "002";
            } // (if validatedSpec.environment != null then validatedSpec.environment { inherit cfg config usesExternalAuth; } else { });
            environmentFiles = validatedSpec.environmentFiles or [ ];
            volumes =
              (lib.optional (!validatedSpec.skipDefaultConfigMount) "${cfg.dataDir}:/config:rw")
                ++ (if validatedSpec.volumes != null then validatedSpec.volumes cfg else [ ]);
            # Note: containerPort defaults to null, so use explicit if/else since Nix 'or'
            # doesn't treat null as falsy (toString null = "")
            ports =
              let containerPort = if validatedSpec.containerPort != null then validatedSpec.containerPort else cfg.port;
              in [ "${toString cfg.port}:${toString containerPort}" ];
            resources = cfg.resources;
            extraOptions =
              let containerPort = if validatedSpec.containerPort != null then validatedSpec.containerPort else cfg.port;
              in [
                "--umask=0027"
                "--pull=newer"
                "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
              ]
              ++ lib.optionals (nfsMountConfig != null && category.hasNfsMount) [
                "--group-add=${toString config.users.groups.${cfg.mediaGroup or "media"}.gid}"
              ]
              ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
                ''--health-cmd=sh -c '[ "$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 http://127.0.0.1:${toString containerPort}${validatedSpec.healthEndpoint or "/"}" = 200 ]' ''
                "--health-interval=${cfg.healthcheck.interval}"
                "--health-timeout=${cfg.healthcheck.timeout}"
                "--health-retries=${toString cfg.healthcheck.retries}"
                "--health-start-period=${cfg.healthcheck.startPeriod}"
                "--health-on-failure=${cfg.healthcheck.onFailure}"
              ]
              ++ lib.optionals (cfg.podmanNetwork or null != null) [
                "--network=${cfg.podmanNetwork}"
              ]
              ++ (if validatedSpec.extraOptions != null then validatedSpec.extraOptions { inherit cfg config; } else [ ]);
          } // (validatedSpec.containerOverrides or { }));

          # Systemd dependencies
          systemd.services."${config.virtualisation.oci-containers.backend}-${name}" = lib.mkMerge [
            (lib.mkIf (cfg.podmanNetwork or null != null) {
              requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
              after = [ "podman-network-${cfg.podmanNetwork}.service" ];
            })
            (lib.mkIf (nfsMountConfig != null) {
              requires = [ nfsMountConfig.mountUnitName ];
              after = [ nfsMountConfig.mountUnitName ];
            })
            # Failure notification hook
            (lib.mkIf (notificationsCfg.enable or false && cfg.notifications != null && cfg.notifications.enable) {
              unitConfig.OnFailure = [ "notify@${name}-failure:%n.service" ];
            })
            # Preseed dependency
            (lib.mkIf (cfg.preseed.enable or false) {
              wants = [ "preseed-${name}.service" ];
              after = [ "preseed-${name}.service" ];
            })
          ];

          # Default notification template
          modules.notifications.templates."${name}-failure" =
            lib.mkIf (notificationsCfg.enable or false && cfg.notifications != null && cfg.notifications.enable) {
              enable = lib.mkDefault true;
              priority = lib.mkDefault "high";
              title = lib.mkDefault ''<b><font color="red">✗ Service Failed: ${validatedSpec.displayName or name}</font></b>'';
              body = lib.mkDefault ''
                <b>Host:</b> ''${hostname}
                <b>Service:</b> <code>''${serviceName}</code>

                The ${validatedSpec.displayName or name} service has entered a failed state.

                <b>Quick Actions:</b>
                1. Check logs:
                   <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
                2. Restart service:
                   <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
              '';
            };
        })

        # Preseed service (automatic data restore)
        (lib.mkIf (cfg.enable && cfg.preseed.enable or false) (
          storageHelpers.mkPreseedService {
            serviceName = name;
            dataset = datasetPath;
            mountpoint = cfg.dataDir;
            mainServiceUnit = mainServiceUnit;
            replicationCfg = replicationConfig;
            datasetProperties = {
              recordsize = validatedSpec.zfsRecordSize;
              compression = validatedSpec.zfsCompression;
            } // (validatedSpec.zfsProperties or { });
            resticRepoUrl = cfg.preseed.repositoryUrl;
            resticPasswordFile = cfg.preseed.passwordFile;
            resticEnvironmentFile = cfg.preseed.environmentFile;
            resticPaths = [ cfg.dataDir ];
            restoreMethods = cfg.preseed.restoreMethods;
            hasCentralizedNotifications = notificationsCfg.enable or false;
            owner = cfg.user;
            group = cfg.group;
          }
        ))

        # Extra config from the service definition
        (lib.mkIf cfg.enable (extraConfig cfg))
      ];
    };

  # Expose category defaults for services that want to reference them
  inherit categoryDefaults;

  # Helper to generate options for native (non-container) services
  mkNativeServiceOptions = { lib, sharedTypes, serviceIds, spec, name, extraOptions ? { } }:
    let
      category = categoryDefaults.${spec.category or "infrastructure"};
    in
    {
      enable = lib.mkEnableOption "${spec.description or name}";

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/${name}";
        description = "Path to ${name} data directory";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = spec.port;
        description = "Port for ${name}";
      };

      reverseProxy = lib.mkOption {
        type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
        default = null;
        description = "Reverse proxy configuration";
      };

      metrics = lib.mkOption {
        type = lib.types.nullOr sharedTypes.metricsSubmodule;
        default = {
          enable = true;
          port = spec.metricsPort or spec.port;
          path = spec.metricsPath or "/metrics";
          labels = {
            service_type = category.serviceType;
            exporter = name;
            function = spec.function or name;
          };
        };
        description = "Prometheus metrics collection";
      };

      logging = lib.mkOption {
        type = lib.types.nullOr sharedTypes.loggingSubmodule;
        default = {
          enable = true;
          journalUnit = "${name}.service";
          labels = {
            service = name;
            service_type = category.serviceType;
          };
        };
        description = "Log shipping configuration";
      };

      backup = lib.mkOption {
        type = lib.types.nullOr sharedTypes.backupSubmodule;
        default = {
          enable = true;
          repository = "nas-primary";
          frequency = "daily";
          tags = category.tags ++ [ name ];
          useSnapshots = true;
          zfsDataset = "tank/services/${name}";
          excludePatterns = [ "**/*.log" "**/cache/**" ];
        };
        description = "Backup configuration";
      };
    } // extraOptions;
}
