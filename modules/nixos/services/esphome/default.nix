# modules/nixos/services/esphome/default.nix
#
# ESPHome dashboard - firmware management for ESP devices
#
# Runs with host networking by default to enable ICMP-based online status
# and mDNS discovery of devices.
#
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  # Resolved lazily after option evaluation - safe to reference here.
  esphomePort = config.modules.services.esphome.port;
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-esphome.service";
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "esphome";
  description = "ESPHome";

  spec = {
    # Core service configuration
    port = 6052;
    image = "ghcr.io/home-operations/esphome:2026.8.0@sha256:d7da3daaf60b07502a929cd8b6a26984a3c07fcbe771798994a040f4110ee2eb";
    operationalProfile = "home-automation";
    displayName = "ESPHome";
    function = "esp_firmware";

    # Match upstream: curl --fail http://localhost:6052/version -A "HealthCheck"
    healthCommand = "curl --fail --silent http://127.0.0.1:${toString esphomePort}/version -A HealthCheck || exit 1";

    # Mix of YAML configs and compiled firmware blobs
    zfsRecordSize = "128K";

    # ESPHome firmware compilation is VERY memory-intensive!
    # PlatformIO/ESP-IDF compilation can easily consume 4-6GB during builds.
    # Idle usage is ~50MB but need 4GB+ headroom for compilation spikes.
    # See: https://github.com/esphome/issues/issues/3488
    resources = {
      memory = "6G";
      memoryReservation = "512M";
      cpus = "4.0"; # Parallel compilation benefits from multiple cores
    };

    environment = { cfg, ... }: {
      ESPHOME_DASHBOARD_USE_PING = if cfg.hostNetwork then "true" else "false";
    };

    # /config comes from the factory's default dataDir mount
    volumes = cfg: [
      "${cfg.cacheDir}:/cache:rw"
      "/etc/localtime:/etc/localtime:ro"
    ];

    extraOptions = { cfg, ... }:
      lib.optionals cfg.hostNetwork [ "--network=host" ];
  };

  extraOptions = {
    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/esphome";
      description = ''
        Directory for PlatformIO/ESPHome build cache. Mounted at /cache inside the container.
        The home-operations ESPHome image uses this for:
        - PLATFORMIO_CORE_DIR=/cache/pio
        - ESPHOME_BUILD_PATH=/cache/build
        - ESPHOME_DATA_DIR=/cache/data

        This is separate from dataDir (/config) to allow excluding from backups while
        keeping firmware compilation fast between rebuilds.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a decrypted secrets.yaml file (usually managed by sops) that should be materialized inside the ESPHome data directory.";
    };

    hostNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use host networking to enable ICMP-based online status and mDNS discovery.";
    };

    # ESPHome healthchecks allow a generous timeout (firmware compiles can
    # starve the dashboard) - overrides the factory defaults.
    healthcheck = lib.mkOption {
      type = lib.types.nullOr mylib.types.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "30s";
        retries = 3;
        startPeriod = "1m";
      };
      description = "Container health check configuration (matches upstream).";
    };

    # ESPHome does not expose native metrics by default - keep metrics opt-in.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Optional Prometheus metrics scraper definition (ESPHome does not expose native metrics by default).";
    };

    # Preserve the pre-factory backup defaults (firmware cache excluded).
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
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
  };

  extraConfig = cfg: {
    assertions = [
      {
        assertion = !(cfg.hostNetwork && cfg.podmanNetwork != null);
        message = "ESPHome cannot use hostNetwork and a custom Podman network simultaneously.";
      }
    ];

    # Firmware builds create files as the container user; keep the dataset
    # group-writable (the factory default is 0750).
    modules.storage.datasets.services.esphome.mode = "0770";

    # Ensure Podman-created subdirectories (e.g., .esphome cache) retain the
    # expected ownership, and provide the build cache directory.
    systemd.tmpfiles.rules = [
      "Z ${cfg.dataDir} 0770 ${cfg.user} ${cfg.group} - -"
      # Cache directory for PlatformIO builds (can grow large, excluded from backups)
      "d ${cfg.cacheDir} 0770 ${cfg.user} ${cfg.group} - -"
    ];

    virtualisation.oci-containers.containers.esphome = {
      # With host networking there is nothing to publish; the dashboard
      # listens on the host directly.
      ports = lib.mkForce (lib.optionals (!cfg.hostNetwork) [
        "${toString cfg.port}:${toString cfg.port}"
      ]);
    };

    systemd.services."${config.virtualisation.oci-containers.backend}-esphome" =
      lib.mkIf (cfg.secretsFile != null) {
        wants = [ "esphome-sync-secrets.service" ];
        after = [ "esphome-sync-secrets.service" ];
      };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."esphome-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        title = "ESPHome dashboard failure";
        body = "ESPHome on ${config.networking.hostName} requires attention.";
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
  };
}
