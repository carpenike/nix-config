{ lib, pkgs, config, ... }:
let
  inherit (lib)
    mkIf
    mkMerge
    mkEnableOption
    mkOption
    mkDefault
    types
    optionalAttrs
    mapAttrsToList
    concatStringsSep
    ;

  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.cooklangFederation;
  notificationsCfg = config.modules.notifications or { };
  storageCfg = config.modules.storage;
  lokiCfg = config.modules.services.loki or null;
  datasetsCfg = storageCfg.datasets or { };
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "cooklang-federation";
  serviceUnitFile = "${serviceName}.service";

  cooklangDataset =
    if (datasetsCfg ? services) && ((datasetsCfg.services or { }) ? "cooklang-federation") then
      datasetsCfg.services."cooklang-federation"
    else
      null;

  defaultDataDir =
    if cooklangDataset != null then
      cooklangDataset.mountpoint or "/var/lib/${serviceName}"
    else
      "/var/lib/${serviceName}";

  defaultIndexDir = "${defaultDataDir}/index";

  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
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

in
{
  options.modules.services.cooklangFederation = {
    enable = mkEnableOption "Cooklang Federation recipe discovery service";

    package = mkOption {
      type = types.package;
      default = pkgs.cooklang-federation;
      description = "Cooklang Federation package to run.";
    };

    user = mkOption {
      type = types.str;
      default = "cooklang-fed";
      description = "System user for Cooklang Federation.";
    };

    group = mkOption {
      type = types.str;
      default = "cooklang";
      description = "Primary group for Cooklang Federation.";
    };

    dataDir = mkOption {
      type = types.path;
      default = defaultDataDir;
      description = "Directory storing database, search index, and state.";
    };

    indexPath = mkOption {
      type = types.path;
      default = defaultIndexDir;
      description = "Path to Tantivy search index (defaults to dataDir/index).";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing the data directory. Required for preseed/backup automation.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for the HTTP server.";
    };

    port = mkOption {
      type = types.port;
      default = 3100;
      description = "Port for the HTTP server.";
    };

    externalUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Public URL advertised to clients/CLI. Defaults to reverse proxy host when unset.";
    };

    databaseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Database connection string (defaults to an on-disk sqlite database inside dataDir).";
      example = "postgres://user:password@localhost/federation";
    };

    apiRateLimit = mkOption {
      type = types.int;
      default = 100;
      description = "API requests per second allowed.";
    };

    crawlerInterval = mkOption {
      type = types.int;
      default = 3600;
      description = "Seconds between feed refreshes.";
    };

    crawlerRateLimit = mkOption {
      type = types.int;
      default = 1;
      description = "Crawler requests per second per domain.";
    };

    maxFeedSize = mkOption {
      type = types.int;
      default = 5242880;
      description = "Maximum feed size in bytes.";
    };

    maxRecipeSize = mkOption {
      type = types.int;
      default = 1048576;
      description = "Maximum recipe size in bytes.";
    };

    rustLog = mkOption {
      type = types.str;
      default = "info,federation=debug";
      description = "RUST_LOG value for the service.";
    };

    github = {
      enable = mkEnableOption "GitHub federation crawler";
      tokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file exporting GITHUB_TOKEN for repository crawling.";
      };
      updateInterval = mkOption {
        type = types.int;
        default = 21600;
        description = "Seconds between GitHub syncs.";
      };
      rateLimitBuffer = mkOption {
        type = types.int;
        default = 500;
        description = "Reserved GitHub API calls to avoid quota exhaustion.";
      };
      maxFileSize = mkOption {
        type = types.int;
        default = 1048576;
        description = "Maximum Cooklang file size when ingesting GitHub repos.";
      };
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables passed to the service.";
    };

    feedConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional override for feeds.yaml that seeds the federation. When unset, the packaged config/feeds.yaml is used.";
    };

    healthcheck = {
      enable = mkEnableOption "Enable HTTP health checks";
      path = mkOption {
        type = types.str;
        default = "/health";
        description = "Endpoint used for health verification.";
      };
      interval = mkOption {
        type = types.str;
        default = "5m";
        description = "systemd timer cadence.";
      };
      timeout = mkOption {
        type = types.str;
        default = "10s";
        description = "curl timeout.";
      };
      metrics = {
        enable = mkEnableOption "Expose health results via node-exporter textfile";
        textfileDir = mkOption {
          type = types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for health metrics.";
        };
      };
      user = mkOption {
        type = types.str;
        default = "cooklang-fed-health";
        description = "Health check system user.";
      };
      group = mkOption {
        type = types.str;
        default = "cooklang-fed-health";
        description = "Group for the health check user.";
      };
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy settings for serving the UI.";
    };

    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus integration (external exporter).";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnitFile;
        labels = {
          service = "cooklang-federation";
          service_type = "recipe_search";
        };
      };
      description = "Log shipping configuration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        tags = mkDefault [ "cooklang" "recipes" "federation" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault (cfg.datasetPath or defaultDatasetPath);
        excludePatterns = mkDefault [ "**/cache/**" "**/*.log" ];
      };
      description = "Restic backup integration.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "homelab-critical" ];
        customMessages.failure = "Cooklang Federation service failed on ${config.networking.hostName}";
      };
      description = "Failure notification routing.";
    };

    preseed = {
      enable = mkEnableOption "automated restore before service start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic credentials.";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Restore method order.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable (
      let
        dataDir = cfg.dataDir;
        indexPath = cfg.indexPath;
        datasetPath = cfg.datasetPath;
        preseedCfg = cfg.preseed;
        preseedEnabled = preseedCfg.enable or false;
        localDatabasePath = "${dataDir}/data/federation.db";
        srcSource = "${cfg.package}/share/cooklang-federation/src";
        stylesSource = "${cfg.package}/share/cooklang-federation/styles";
        tailwindConfigSource = "${cfg.package}/share/cooklang-federation/tailwind.config.js";
        tailwindPackage = pkgs.tailwindcss_3;
        tailwindBinary = lib.getExe tailwindPackage;
        bundledFeedConfig = "${cfg.package}/share/cooklang-federation/config/feeds.yaml";
        usesDefaultSqlite = cfg.databaseUrl == null;
        feedConfigDestination = "${dataDir}/config/feeds.yaml";
        feedConfigSource = if cfg.feedConfigFile != null then cfg.feedConfigFile else bundledFeedConfig;
        databaseUrl =
          if cfg.databaseUrl != null then cfg.databaseUrl
          else "sqlite://${localDatabasePath}";
        effectiveExternalUrl =
          if cfg.externalUrl != null then cfg.externalUrl
          else if cfg.reverseProxy != null && cfg.reverseProxy.enable then "https://${cfg.reverseProxy.hostName}"
          else "http://${cfg.listenAddress}:${toString cfg.port}";

        envVars = {
          DATABASE_URL = databaseUrl;
          HOST = cfg.listenAddress;
          PORT = toString cfg.port;
          EXTERNAL_URL = effectiveExternalUrl;
          API_RATE_LIMIT = toString cfg.apiRateLimit;
          CRAWLER_INTERVAL = toString cfg.crawlerInterval;
          RATE_LIMIT = toString cfg.crawlerRateLimit;
          MAX_FEED_SIZE = toString cfg.maxFeedSize;
          MAX_RECIPE_SIZE = toString cfg.maxRecipeSize;
          INDEX_PATH = indexPath;
          RUST_LOG = cfg.rustLog;
          FEED_CONFIG_PATH = feedConfigDestination;
          API_MAX_LIMIT = "100";
          WEB_DEFAULT_LIMIT = "50";
          FEED_PAGE_SIZE = "20";
          MAX_SEARCH_RESULTS = "1000";
          MAX_REQUEST_BODY_SIZE = "10485760";
          MAX_PAGES = "10000";
          CRAWLER_MAX_CONCURRENCY = "4";
          CRON_ENABLED = "true";
          GITHUB_UPDATE_INTERVAL = toString cfg.github.updateInterval;
          GITHUB_RATE_LIMIT_BUFFER = toString cfg.github.rateLimitBuffer;
          GITHUB_MAX_FILE_SIZE = toString cfg.github.maxFileSize;
        } // cfg.extraEnvironment;

        envList = mapAttrsToList (k: v: "${k}=${v}") (lib.filterAttrs (_: v: v != null) envVars);
        envFiles = lib.optional (cfg.github.enable && cfg.github.tokenFile != null) cfg.github.tokenFile;
      in
      {
        assertions = [
          {
            assertion = cfg.user != "root";
            message = "Cooklang Federation cannot run as root.";
          }
          {
            assertion = cfg.port > 0 && cfg.port < 65536;
            message = "Cooklang Federation port must be between 1 and 65535.";
          }
          {
            assertion = !(cfg.enable && lokiCfg != null && (lokiCfg.enable or false) && cfg.port == (lokiCfg.port or 3100));
            message = "Cooklang Federation port conflicts with Loki; choose different modules.services.cooklangFederation.port.";
          }
          {
            assertion = !(cfg.backup != null && cfg.backup.enable) || cfg.backup.repository != null;
            message = "Cooklang Federation backup.enable requires backup.repository.";
          }
          {
            assertion = !preseedEnabled || (preseedCfg.repositoryUrl != "" && preseedCfg.passwordFile != null && datasetPath != null);
            message = "Cooklang Federation preseed requires repositoryUrl, passwordFile, and datasetPath.";
          }
        ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          description = "Cooklang Federation service user";
          home = lib.mkForce "/var/empty";
        };

        users.groups.${cfg.group} = { };

        users.users.${cfg.healthcheck.user} = mkIf cfg.healthcheck.enable {
          isSystemUser = true;
          group = cfg.healthcheck.group;
          description = "Cooklang Federation healthcheck user";
          extraGroups = lib.optional (cfg.healthcheck.metrics.enable) "node-exporter";
          home = lib.mkForce "/var/empty";
        };

        users.groups.${cfg.healthcheck.group} = mkIf cfg.healthcheck.enable { };

        systemd.tmpfiles.rules = [
          "d ${dataDir} 0750 ${cfg.user} ${cfg.group} - -"
          "d ${indexPath} 0750 ${cfg.user} ${cfg.group} - -"
        ] ++ lib.optional (cfg.healthcheck.metrics.enable) "d ${cfg.healthcheck.metrics.textfileDir} 0775 node-exporter node-exporter - -";

        modules.storage.datasets.services."cooklang-federation" = mkIf (datasetPath != null) {
          mountpoint = mkDefault dataDir;
          recordsize = mkDefault "16K";
          compression = mkDefault "zstd";
          properties = mkDefault { "com.sun:auto-snapshot" = "true"; };
          owner = mkDefault cfg.user;
          group = mkDefault cfg.group;
          mode = mkDefault "0750";
        };

        systemd.services.${serviceName} = mkMerge [
          {
            description = "Cooklang Federation";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ] ++ lib.optional (datasetPath != null) "zfs-mount.service" ++ lib.optional preseedEnabled "preseed-${serviceName}.service";
            requires = lib.optional (datasetPath != null) "zfs-mount.service" ++ lib.optional preseedEnabled "preseed-${serviceName}.service";
            unitConfig =
              {
                RequiresMountsFor = [ dataDir ];
              }
              // (optionalAttrs (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
                OnFailure = [ "notify@cooklang-federation-failure:%n.service" ];
              });
            serviceConfig = {
              Type = "simple";
              User = cfg.user;
              Group = cfg.group;
              WorkingDirectory = dataDir;
              Environment = envList;
              EnvironmentFile = envFiles;
              PermissionsStartOnly = true;
              ExecStartPre = pkgs.writeShellScript "${serviceName}-prepare" ''
                set -euo pipefail
                install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${dataDir}
                install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${indexPath}
                if [ -d "${srcSource}" ]; then
                  rm -rf ${dataDir}/src
                  cp -r --no-preserve=ownership "${srcSource}" ${dataDir}/
                  chown -R ${cfg.user}:${cfg.group} ${dataDir}/src
                fi
                if [ -d "${stylesSource}" ]; then
                  rm -rf ${dataDir}/styles
                  cp -r --no-preserve=ownership "${stylesSource}" ${dataDir}/
                  chown -R ${cfg.user}:${cfg.group} ${dataDir}/styles
                fi
                if [ -f "${tailwindConfigSource}" ]; then
                  cp -f "${tailwindConfigSource}" ${dataDir}/tailwind.config.js
                  chown ${cfg.user}:${cfg.group} ${dataDir}/tailwind.config.js
                fi
                if [ -x "${tailwindBinary}" ] && [ -f "${dataDir}/tailwind.config.js" ] && [ -f "${dataDir}/styles/input.css" ]; then
                  cd ${dataDir}
                  ${tailwindBinary} \
                    -c ${dataDir}/tailwind.config.js \
                    -i styles/input.css \
                    -o src/web/static/css/output.css \
                    --minify
                  chown ${cfg.user}:${cfg.group} src/web/static/css/output.css
                fi
                install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${dataDir}/config
                if [ -f "${feedConfigSource}" ]; then
                  install -D -m 0640 -o ${cfg.user} -g ${cfg.group} "${feedConfigSource}" ${feedConfigDestination}
                fi
                ${lib.optionalString usesDefaultSqlite ''
                  install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${dataDir}/data
                  if [ ! -f "${localDatabasePath}" ]; then
                    install -m 0640 -o ${cfg.user} -g ${cfg.group} /dev/null "${localDatabasePath}"
                  fi
                ''}
              '';
              ExecStart = concatStringsSep " " [
                "${cfg.package}/bin/federation"
                "serve"
              ];
              Restart = "on-failure";
              RestartSec = "5s";
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [ dataDir ];
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
              MemoryMax = "1G";
              CPUQuota = "75%";
            };
          }
        ];

        modules.services.caddy.virtualHosts.cooklangFederation = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) (
          let backendCfg = lib.attrByPath [ "backend" ] { } cfg.reverseProxy;
          in {
            enable = true;
            hostName = cfg.reverseProxy.hostName;
            backend = {
              scheme = backendCfg.scheme or "http";
              host = backendCfg.host or cfg.listenAddress;
              port = backendCfg.port or cfg.port;
            };
            auth = cfg.reverseProxy.auth;
            security = cfg.reverseProxy.security;
            extraConfig = cfg.reverseProxy.extraConfig or "";
          }
        );

        modules.notifications.templates = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          "cooklang-federation-failure" = {
            enable = mkDefault true;
            priority = mkDefault "high";
            title = mkDefault ''<b><font color="red">✗ Service Failed: Cooklang Federation</font></b>'';
            body = mkDefault ''
              <b>Host:</b> ''${hostname}
              <b>Service:</b> <code>''${serviceName}</code>
              Investigate logs: <code>journalctl -u ''${serviceName} -n 200</code>
              Restart: <code>systemctl restart ''${serviceName}</code>
            '';
          };
        };

        systemd.services."${serviceName}-healthcheck" = mkIf cfg.healthcheck.enable {
          description = "Cooklang Federation Health Check";
          after = [ serviceUnitFile ];
          requires = [ serviceUnitFile ];
          serviceConfig = {
            Type = "oneshot";
            User = cfg.healthcheck.user;
            Group = cfg.healthcheck.group;
            ReadWritePaths = lib.optional cfg.healthcheck.metrics.enable cfg.healthcheck.metrics.textfileDir;
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
                          METRICS_FILE="$METRICS_DIR/cooklang_federation.prom"
                          if [ ! -d "$METRICS_DIR" ]; then
                            echo "Metrics directory $METRICS_DIR missing" >&2
                            exit 1
                          fi
                          TS=$(date +%s)
                          cat > "$METRICS_FILE.tmp" <<EOF
            # HELP cooklang_federation_up Service health (1=up)
            # TYPE cooklang_federation_up gauge
            cooklang_federation_up{host="${config.networking.hostName}"} $STATUS
            # HELP cooklang_federation_healthcheck_timestamp Timestamp of last check
            # TYPE cooklang_federation_healthcheck_timestamp gauge
            cooklang_federation_healthcheck_timestamp{host="${config.networking.hostName}"} $TS
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
          description = "Cooklang Federation health timer";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = cfg.healthcheck.interval;
            AccuracySec = "30s";
          };
        };
      }
    ))

    (mkIf (cfg.enable && cfg.backup != null && cfg.backup.enable) {
      modules.backup.restic.jobs.cooklangFederation = {
        enable = true;
        repository = cfg.backup.repository;
        paths = [ cfg.dataDir ];
        tags = cfg.backup.tags or [ "cooklang" "federation" ];
        excludePatterns = cfg.backup.excludePatterns or [ "**/cache/**" "**/*.log" ];
        useSnapshots = cfg.backup.useSnapshots or true;
      };
    })

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = cfg.datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnitFile;
        replicationCfg =
          let
            datasetPath = cfg.datasetPath;
            foundReplication = if datasetPath != null then findReplication datasetPath else null;
          in
          if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then null else
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
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        timeoutSec = 1800;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
