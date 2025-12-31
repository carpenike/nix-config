{ lib, mylib, pkgs, config, podmanLib, ... }:

let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.esphome;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;

  hasCentralizedNotifications = notificationsCfg.enable or false;
  serviceName = "esphome";
  backend = config.virtualisation.oci-containers.backend;
  mainServiceUnit = "${backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";
  esphomePort = cfg.port;

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

in
{
  options.modules.services.esphome = {
    enable = lib.mkEnableOption "ESPHome dashboard container";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/esphome";
      description = "Persistent configuration directory mounted at /config inside the container.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a decrypted secrets.yaml file (usually managed by sops) that should be materialized inside the ESPHome data directory.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6052;
      description = "Local HTTP port used by the ESPHome dashboard.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/home-operations/esphome:2025.12.3@sha256:d000147ad5598dbcabe59be0426b0b52b095d7f51b5e2a97addf68072218581f";
      description = ''
        Container image for ESPHome (home-operations).
        Pin to specific version with digest for immutability.
        Use Renovate bot to automate version updates.
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "UTC";
      description = "Timezone passed through to the container.";
    };

    hostNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use host networking to enable ICMP-based online status and mDNS discovery.";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Podman network name when not using host networking.";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        # ESPHome firmware compilation is VERY memory-intensive!
        # PlatformIO/ESP-IDF compilation can easily consume 4-6GB during builds.
        # Idle usage is ~50MB but need 4GB+ headroom for compilation spikes.
        # See: https://github.com/esphome/issues/issues/3488
        memory = "6G";
        memoryReservation = "512M";
        cpus = "4.0"; # Parallel compilation benefits from multiple cores
      };
      description = "Container resource limits. ESPHome compilation requires significant memory (4GB+ recommended).";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for exposing the dashboard via Caddy.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = lib.mkDefault "${backend}-${serviceName}.service";
        labels = {
          service = serviceName;
          service_type = "automation";
        };
      };
      description = "Log shipping configuration for ESPHome.";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Optional Prometheus metrics scraper definition (ESPHome does not expose native metrics by default).";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "esphome" "firmware" "config" ];
        useSnapshots = true;
        zfsDataset = "tank/services/esphome";
        excludePatterns = [
          "**/.esphome/cache/**"
          "**/.esphome/build/**"
          "**/*.log"
        ];
      };
      description = "Backup configuration using the unified backup system.";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "automation-alerts" ];
        };
        customMessages.failure = "ESPHome dashboard failed on ${config.networking.hostName}";
      };
      description = "Notification preferences for ESPHome failures.";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "30s";
        retries = 3;
        startPeriod = "1m";
      };
      description = "Container health check configuration (matches upstream).";
    };

    preseed = {
      enable = lib.mkEnableOption "Automatic data restore prior to starting the container";
      repositoryUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Restic repository URL used for preseeding.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to the Restic password file.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional Restic environment file (for B2/S3 credentials).";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Restore methods evaluated in order when preseeding.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !(cfg.hostNetwork && cfg.podmanNetwork != null);
          message = "ESPHome cannot use hostNetwork and a custom Podman network simultaneously.";
        }
        {
          assertion = cfg.backup == null || !cfg.backup.enable || cfg.backup.repository != null;
          message = "ESPHome backup.enable requires backup.repository to be set.";
        }
        {
          assertion = !cfg.preseed.enable || (cfg.preseed.repositoryUrl != null && cfg.preseed.repositoryUrl != "");
          message = "ESPHome preseed.enable requires repositoryUrl to be set.";
        }
        {
          assertion = !cfg.preseed.enable || cfg.preseed.passwordFile != null;
          message = "ESPHome preseed.enable requires passwordFile to be set.";
        }
      ];

      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "128K"; # mix of YAML configs and compiled firmware blobs
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = "esphome";
        group = "esphome";
        mode = "0770";
      };

      users.groups.esphome = { };
      users.users.esphome = {
        isSystemUser = true;
        group = "esphome";
        home = cfg.dataDir;
        description = "ESPHome service account";
      };

      # Ensure Podman-created subdirectories (e.g., .esphome cache) retain the
      # expected ownership. Other containerized services achieve this via their
      # tmpfiles entries, so mirror that behavior here with a recursive rule.
      systemd.tmpfiles.rules = [
        "Z ${cfg.dataDir} 0770 esphome esphome - -"
      ];

      modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = esphomePort;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;
        environment = {
          TZ = cfg.timezone;
          ESPHOME_DASHBOARD_USE_PING = if cfg.hostNetwork then "true" else "false";
        };
        volumes = [
          "${cfg.dataDir}:/config:rw"
          "/etc/localtime:/etc/localtime:ro"
        ];
        ports = lib.optionals (!cfg.hostNetwork) [
          "${toString esphomePort}:${toString esphomePort}"
        ];
        resources = cfg.resources;
        extraOptions =
          (lib.optionals cfg.hostNetwork [ "--network=host" ])
          ++ (lib.optionals (!cfg.hostNetwork && cfg.podmanNetwork != null) [ "--network=${cfg.podmanNetwork}" ])
          ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
            # Match upstream: curl --fail http://localhost:6052/version -A "HealthCheck"
            "--health-cmd=curl --fail --silent http://127.0.0.1:${toString esphomePort}/version -A HealthCheck || exit 1"
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
            "--health-on-failure=${cfg.healthcheck.onFailure}"
          ];
      };

      systemd.services.${mainServiceUnit} = lib.mkMerge [
        (lib.mkIf (cfg.podmanNetwork != null && !cfg.hostNetwork) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@esphome-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-esphome.service" ];
          after = [ "preseed-esphome.service" ];
        })
        (lib.mkIf (cfg.secretsFile != null) {
          wants = [ "esphome-sync-secrets.service" ];
          after = [ "esphome-sync-secrets.service" ];
        })
      ];

      # Health check is handled natively by Podman container (see extraOptions above)
      # No separate systemd timer needed - Prometheus scrapes container health status

      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "esphome-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault "ESPHome dashboard failure";
          body = lib.mkDefault ''ESPHome on ${config.networking.hostName} requires attention.'';
        };
      };

      systemd.services."esphome-sync-secrets" = lib.mkIf (cfg.secretsFile != null) (
        let
          syncScript = pkgs.writeShellScript "esphome-sync-secrets" ''
            set -euo pipefail
            install -d -m 0750 -o esphome -g esphome ${cfg.dataDir}
            install -m 0600 -o esphome -g esphome ${cfg.secretsFile} ${cfg.dataDir}/secrets.yaml
            if ${pkgs.systemd}/bin/systemctl is-active --quiet ${mainServiceUnit}; then
              ${pkgs.systemd}/bin/systemctl restart --no-block ${mainServiceUnit}
            fi
          '';
        in
        {
          description = "Sync ESPHome secrets.yaml from sops";
          before = [ mainServiceUnit ];
          requiredBy = [ mainServiceUnit ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = syncScript;
          };
        }
      );

      systemd.paths."esphome-sync-secrets" = lib.mkIf (cfg.secretsFile != null) {
        description = "Watch ESPHome secrets.yaml for changes";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = cfg.secretsFile;
          Unit = "esphome-sync-secrets.service";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
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
        owner = "esphome";
        group = "esphome";
      }
    ))
  ];
}
