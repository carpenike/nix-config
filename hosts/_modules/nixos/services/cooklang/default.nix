# Cooklang Service Module (Native Binary Service)
#
# This module configures Cooklang CLI's web server for managing cooking recipes
# in the Cooklang markup format. Cooklang is a plain-text recipe markup language.
# See: https://cooklang.org and https://github.com/cooklang/cookcli
#
# DESIGN RATIONALE (Nov 15, 2025):
# - No native NixOS module exists, so we create a custom systemd service
# - Uses native Rust binary (not container) for simplicity and performance
# - Recipes stored on ZFS for durability and snapshot capabilities
# - Follows modular design patterns: reverse proxy, backup, monitoring, preseed
# - Minimal resource footprint (<100MB RAM typical)
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkMerge mkEnableOption mkOption mkDefault types;

  # Import storage helpers for preseed service generation
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.cooklang;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  datasetsCfg = storageCfg.datasets or {};
  hasCentralizedNotifications = notificationsCfg.enable or false;
  preseedCfg = cfg.preseed;
  preseedEnabled = preseedCfg.enable or false;
  cooklangDataset =
    if storageCfg.datasets or {} ? services && (storageCfg.datasets.services or {}) ? cooklang then
      storageCfg.datasets.services.cooklang
    else
      null;
  datasetRoot =
    if datasetsCfg ? parentDataset then
      datasetsCfg.parentDataset
    else
      "rpool/safe/persist";

  serviceName = "cooklang";
  serviceUnitFile = "${serviceName}.service";

  # Default to ZFS dataset path if storage is configured
  defaultRecipeDir =
    if cooklangDataset != null then
      cooklangDataset.mountpoint or "/var/lib/cooklang/recipes"
    else
      "/var/lib/cooklang/recipes";

  # Generate aisle.conf content from settings
  aisleConf = pkgs.writeText "aisle.conf" cfg.settings.aisle;

  # Generate pantry.conf content from settings (TOML format)
  pantryConf =
    if cfg.settings.pantry != null then
      (pkgs.formats.toml {}).generate "pantry.conf" cfg.settings.pantry
    else
      null;

  # Recursively find the replication config from the most specific dataset path upwards
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  # Determine ZFS dataset path for replication
  datasetPath =
    if cooklangDataset != null then
      "${datasetRoot}/${serviceName}"
    else
      null;

  foundReplication =
    if datasetPath != null then
      findReplication datasetPath
    else
      null;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.cooklang = {
    enable = mkEnableOption "Cooklang recipe management server";

    package = mkOption {
      type = types.package;
      default = pkgs.cooklang-cli;
      description = "The Cooklang CLI package to use";
    };

    user = mkOption {
      type = types.str;
      default = "cooklang";
      description = "User account under which Cooklang runs";
    };

    group = mkOption {
      type = types.str;
      default = "cooklang";
      description = "Group under which Cooklang runs";
    };

    recipeDir = mkOption {
      type = types.path;
      default = defaultRecipeDir;
      description = ''
        Directory containing recipe files (.cook) and configuration.
        Should point to a ZFS dataset mountpoint for durability.
      '';
      example = "/data/cooklang/recipes";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/cooklang";
      description = "State directory for Cooklang server runtime data";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to bind the web server to (use 127.0.0.1 for localhost only)";
    };

    port = mkOption {
      type = types.port;
      default = 9080;
      description = "Port for the Cooklang web server";
    };

    openBrowser = mkOption {
      type = types.bool;
      default = false;
      description = "Automatically open browser on server start (disable for server deployments)";
    };

    settings = {
      aisle = mkOption {
        type = types.lines;
        default = ''
          [produce]
          tomatoes
          onions
          garlic

          [dairy]
          milk
          cheese
          butter

          [meat]
          chicken
          beef

          [pantry]
          flour
          sugar
          salt
          pasta
          rice
        '';
        description = ''
          Content for aisle.conf - organizes ingredients by store section.
          Uses INI-like format with section headers.
        '';
      };

      pantry = mkOption {
        type = types.nullOr (types.attrsOf types.attrs);
        default = null;
        description = ''
          Content for pantry.conf - tracks ingredient inventory.
          Set to null to skip pantry.conf generation (for stateful management).
          Uses TOML format: sections with key-value pairs.
        '';
        example = {
          pantry = {
            salt = { quantity = "1kg"; low = "500g"; };
            oil = { quantity = "500ml"; low = "200ml"; };
          };
          dairy = {
            milk = { quantity = "1L"; expire = "2025-11-20"; low = "500ml"; };
          };
        };
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Cooklang web interface";
    };

    # Standardized metrics collection (limited - no native metrics)
    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = ''
        Prometheus metrics collection for Cooklang.
        Note: Cooklang doesn't expose native metrics endpoint.
        This enables systemd unit monitoring only.
      '';
    };

    # Standardized logging integration
    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnitFile;
        labels = {
          service = "cooklang";
          service_type = "recipe_management";
        };
      };
      description = "Log shipping configuration";
    };

    # Standardized backup integration
    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for recipe files";
    };

    # Standardized notification integration
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "homelab-critical" ];
        customMessages = {
          failure = "Cooklang service failure on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Cooklang failures";
    };

    healthcheck = {
      enable = mkEnableOption "periodic Cooklang HTTP health check";

      path = mkOption {
        type = types.str;
        default = "/";
        description = "HTTP path to probe for health";
      };

      interval = mkOption {
        type = types.str;
        default = "5m";
        description = "How often to run the health check timer";
      };

      timeout = mkOption {
        type = types.str;
        default = "10s";
        description = "Timeout per curl invocation";
      };

      startPeriod = mkOption {
        type = types.str;
        default = "2m";
        description = "Delay before first health check after boot";
      };

      metrics = {
        enable = mkEnableOption "publish node exporter textfile metrics";
        textfileDir = mkOption {
          type = types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for Node Exporter textfile metrics";
        };
      };
    };

    # Disaster recovery / preseed configuration (aligned with shared pattern)
    preseed = {
      enable = mkEnableOption "preseed/restore on fresh deployment";

      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic repository password file";
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for cloud credentials)";
      };

      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried sequentially
          until one succeeds.
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = lib.mkForce "/var/empty";
        description = "Cooklang service user";
      };

      users.groups.${cfg.group} = {};

      systemd.tmpfiles.rules = [
        "d '${cfg.recipeDir}/config' 0750 ${cfg.user} ${cfg.group} - -"
      ];

      modules.storage.datasets.services.cooklang = {
        mountpoint = mkDefault cfg.recipeDir;
        recordsize = mkDefault "16K";
        compression = mkDefault "zstd";
        properties = mkDefault {
          "com.sun:auto-snapshot" = "true";
        };
        owner = mkDefault cfg.user;
        group = mkDefault cfg.group;
        mode = mkDefault "0750";
      };

      modules.services.cooklang.reverseProxy.backend = mkIf (cfg.reverseProxy != null) (mkDefault {
        scheme = "http";
        host = cfg.listenAddress;
        port = cfg.port;
      });

      systemd.services.${serviceName} = mkMerge [
        {
          description = "Cooklang Recipe Server";
          wantedBy = [ "multi-user.target" ];
          after =
            [ "network.target" ]
            ++ lib.optional (datasetPath != null) "zfs-mount.service"
            ++ lib.optional preseedEnabled "preseed-${serviceName}.service";
          requires =
            []
            ++ lib.optional (datasetPath != null) "zfs-mount.service"
            ++ lib.optional preseedEnabled "preseed-${serviceName}.service";

          unitConfig.RequiresMountsFor = [ cfg.recipeDir ];

          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = cfg.group;
            StateDirectory = serviceName;
            StateDirectoryMode = "0750";
            WorkingDirectory = cfg.recipeDir;
            PrivateTmp = true;
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [
              cfg.recipeDir
              "/var/lib/${serviceName}"
            ];
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
            MemoryMax = "512M";
            CPUQuota = "50%";
            TasksMax = "64";
            ExecStartPre = pkgs.writeShellScript "cooklang-config-setup" ''
              set -euo pipefail

              mkdir -p ${cfg.recipeDir}/config
              chown ${cfg.user}:${cfg.group} ${cfg.recipeDir}/config

              install -m 640 -o ${cfg.user} -g ${cfg.group} ${aisleConf} ${cfg.recipeDir}/config/aisle.conf

              ${lib.optionalString (pantryConf != null) ''
                install -m 640 -o ${cfg.user} -g ${cfg.group} ${pantryConf} ${cfg.recipeDir}/config/pantry.conf
              ''}

              ${lib.optionalString (pantryConf == null) ''
                if [ ! -f ${cfg.recipeDir}/config/pantry.conf ]; then
                  touch ${cfg.recipeDir}/config/pantry.conf
                  chown ${cfg.user}:${cfg.group} ${cfg.recipeDir}/config/pantry.conf
                  chmod 640 ${cfg.recipeDir}/config/pantry.conf
                fi
              ''}
            '';
            ExecStart = lib.escapeShellArgs (
              [
                "${cfg.package}/bin/cook"
                "server"
                "--host"
                cfg.listenAddress
                "--port"
                (toString cfg.port)
              ] ++ lib.optional (!cfg.openBrowser) "--no-open"
            );
            Restart = "on-failure";
            RestartSec = "10s";
          };
        }
        (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@cooklang-failure:%n.service" ];
        })
      ];

      modules.services.caddy.virtualHosts.cooklang = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) (
        let
          backendCfg = lib.attrByPath [ "backend" ] {} cfg.reverseProxy;
        in {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = {
            scheme = backendCfg.scheme or "http";
            host = backendCfg.host or cfg.listenAddress;
            port = backendCfg.port or cfg.port;
          };
          auth = cfg.reverseProxy.auth;
          authelia = cfg.reverseProxy.authelia;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig or "";
        }
      );

      modules.services.authelia.accessControl.declarativelyProtectedServices.cooklang = mkIf (
        config.modules.services.authelia.enable &&
        cfg.reverseProxy != null &&
        cfg.reverseProxy.enable &&
        cfg.reverseProxy.authelia != null &&
        cfg.reverseProxy.authelia.enable
      ) (
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
            ++ authCfg.bypassResources;
        }
      );

      modules.alerting.rules = mkMerge [
        {
          "cooklang-service-down" = {
            type = "promql";
            alertname = "CooklangServiceDown";
            expr = ''
              systemd_unit_state{name="${serviceUnitFile}",state="active"} == 0
            '';
            for = "5m";
            severity = "high";
            labels = {
              service = "cooklang";
              category = "systemd";
            };
            annotations = {
              title = "Cooklang Service Down";
              body = "The Cooklang service on {{ $labels.instance }} has been down for 5 minutes.";
            };
          };
        }

        (mkIf (datasetPath != null) {
          "cooklang-dataset-unavailable" = {
            type = "promql";
            alertname = "CooklangDatasetUnavailable";
            expr = ''
              zfs_dataset_available{dataset="${datasetPath}"} == 0
            '';
            for = "2m";
            severity = "critical";
            labels = {
              service = "cooklang";
              category = "storage";
            };
            annotations = {
              title = "Cooklang Dataset Unavailable";
              body = "The ZFS dataset for Cooklang (${datasetPath}) is unavailable.";
            };
          };
        })
      ];

      modules.notifications.templates = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "cooklang-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Cooklang</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            Cooklang entered a failed state. Review logs and restart if needed.

            <b>Quick Actions:</b>
            1. Inspect logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 200'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'sudo systemctl restart ''${serviceName}'</code>
          '';
        };
      };

      systemd.services."${serviceName}-healthcheck" = mkIf cfg.healthcheck.enable {
        description = "Cooklang Health Check";
        after = [ "${serviceName}.service" ];
        requires = [ "${serviceName}.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
        };
        script = ''
          set -euo pipefail
          URL="http://${cfg.listenAddress}:${toString cfg.port}${cfg.healthcheck.path}"
          STATUS=0
          if ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time ${cfg.healthcheck.timeout} "$URL" >/dev/null; then
            STATUS=1
          fi

          ${lib.optionalString cfg.healthcheck.metrics.enable ''
            METRICS_DIR="${cfg.healthcheck.metrics.textfileDir}"
            METRICS_FILE="$METRICS_DIR/cooklang.prom"
            mkdir -p "$METRICS_DIR"
            TS=$(date +%s)
            cat > "$METRICS_FILE.tmp" <<EOF
# HELP cooklang_up Cooklang HTTP health status (1=up, 0=down)
# TYPE cooklang_up gauge
cooklang_up{host="${config.networking.hostName}"} $STATUS

# HELP cooklang_last_check_timestamp Timestamp of last Cooklang health check
# TYPE cooklang_last_check_timestamp gauge
cooklang_last_check_timestamp{host="${config.networking.hostName}"} $TS
EOF
            mv "$METRICS_FILE.tmp" "$METRICS_FILE"
          ''}

          if [ "$STATUS" -eq 1 ]; then
            exit 0
          else
            exit 1
          fi
        '';
      };

      systemd.timers."${serviceName}-healthcheck" = mkIf cfg.healthcheck.enable {
        description = "Cooklang health check timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          AccuracySec = "30s";
        };
      };

      assertions = [
        {
          assertion = cfg.user != "root";
          message = "Cooklang service cannot run as root user.";
        }
        {
          assertion = ! lib.hasPrefix "/nix/store" cfg.recipeDir
                     && ! lib.hasPrefix "/etc" cfg.recipeDir
                     && ! lib.hasPrefix "/boot" cfg.recipeDir;
          message = "Cooklang recipeDir cannot be located in a critical system path (/nix/store, /etc, /boot).";
        }
        {
          assertion = preseedEnabled -> (preseedCfg.repositoryUrl != "");
          message = "Cooklang preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = preseedEnabled -> (preseedCfg.passwordFile != null);
          message = "Cooklang preseed.enable requires preseed.passwordFile to be set.";
        }
        {
          assertion = cfg.recipeDir != "";
          message = "Cooklang recipeDir must be set";
        }
        {
          assertion = cfg.port > 0 && cfg.port < 65536;
          message = "Cooklang port must be between 1 and 65535";
        }
        {
          assertion = (cfg.backup == null) || (!cfg.backup.enable) || (cfg.backup.repository != null);
          message = "Cooklang backup.enable requires backup.repository to be set.";
        }
      ];
    })

    (mkIf (cfg.enable && cfg.backup != null && cfg.backup.enable) {
      modules.backup.restic.jobs.cooklang = {
        enable = true;
        repository = cfg.backup.repository;
        paths = [ cfg.recipeDir ];
        tags = cfg.backup.tags or [ "cooklang" "recipes" ];
        excludePatterns = cfg.backup.excludePatterns or [ "**/cache/**" "**/*.log" ];
        useSnapshots = cfg.backup.useSnapshots or true;
      };
    })

    (mkIf (cfg.enable && preseedEnabled) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.recipeDir;
        mainServiceUnit = serviceUnitFile;
        replicationCfg = replicationConfig;
        datasetProperties =
          let
            baseProperties = {
              recordsize = "16K";
              compression = "zstd";
              "com.sun:auto-snapshot" = "true";
            };
          in
          if cooklangDataset != null then
            baseProperties // (cooklangDataset.properties or {})
          else
            baseProperties;
        resticRepoUrl = preseedCfg.repositoryUrl;
        resticPasswordFile = preseedCfg.passwordFile;
        resticEnvironmentFile = preseedCfg.environmentFile;
        resticPaths = [ cfg.recipeDir ];
        restoreMethods = preseedCfg.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        timeoutSec = 1800;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
