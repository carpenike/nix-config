{ lib, pkgs, config, podmanLib, ... }:

let
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit lib pkgs; };

  cfg = config.modules.services.esphome;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;

  hasCentralizedNotifications = notificationsCfg.enable or false;
  serviceName = "esphome";
  backend = config.virtualisation.oci-containers.backend;
  mainServiceUnit = "${backend}-${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";
  esphomePort = cfg.port;

  healthcheckScript = pkgs.writeShellScript "esphome-healthcheck" ''
    set -euo pipefail
    url="http://127.0.0.1:${toString esphomePort}/"
    if ! ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 5 "$url" >/dev/null; then
      echo "ESPHome dashboard probe failed for $url" >&2
      exit 1
    fi
  '';

in {
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
      default = "ghcr.io/esphome/esphome:2025.11.1";
      description = "Container image reference (pin to a digest for reproducible deployments).";
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
        memory = "512M";
        memoryReservation = "256M";
        cpus = "1.0";
      };
      description = "Container resource limits.";
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

    healthcheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the periodic HTTP probe for the dashboard.";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Timer interval between HTTP health checks.";
      };
      timeout = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout applied to the HTTP probe.";
      };
      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "1m";
        description = "Grace period after service start before marking probes as failures.";
      };
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
        mode = "0750";
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
        "Z ${cfg.dataDir} 0750 esphome esphome - -"
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
        authelia = cfg.reverseProxy.authelia;
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
          ++ lib.optionals cfg.healthcheck.enable [
            ''--health-cmd=sh -c 'exec 3<>/dev/tcp/127.0.0.1/${toString esphomePort}' ''
            "--health-interval=0s"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=3"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
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

      systemd.timers.esphome-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "ESPHome dashboard health check timer";
        wantedBy = [ "timers.target" ];
        after = [ mainServiceUnit ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.esphome-healthcheck = lib.mkIf cfg.healthcheck.enable {
        description = "ESPHome dashboard HTTP probe";
        after = [ mainServiceUnit ];
        requires = [ mainServiceUnit ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = healthcheckScript;
        };
      };

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
        in {
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
        replicationCfg = storageHelpers.findReplication config datasetPath;
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
