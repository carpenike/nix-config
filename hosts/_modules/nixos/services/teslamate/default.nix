{ lib, pkgs, config, podmanLib, ... }:
with lib;
let
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  cfg = config.modules.services.teslamate;
  notificationsCfg = config.modules.notifications or {};
  hasCentralizedNotifications = notificationsCfg.enable or false;
  storageCfg = config.modules.storage or {};
  datasetsCfg = storageCfg.datasets or {};

  serviceName = "teslamate";
  backend = config.virtualisation.oci-containers.backend;
  serviceAttrName = "${backend}-${serviceName}";
  mainServiceUnit = "${serviceAttrName}.service";

  teslamateDashboardsSrc = pkgs.fetchzip {
    url = "https://github.com/adriankumpf/teslamate/archive/refs/tags/v2.2.0.tar.gz";
    sha256 = "sha256-M4Bte5MCZGzKJoFcXzTVLFRHmgqVjR5TyQb5bTeEBws=";
  };
  defaultDashboardsPath = "${teslamateDashboardsSrc}/grafana/dashboards";
  grafanaCredentialName = "teslamate-db-password";
  grafanaCredentialPath = "/run/credentials/grafana.service/${grafanaCredentialName}";

  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  # Recursively locate replication config from parent datasets (if any)
  findReplication = dsPath:
    if dsPath == "" || dsPath == null then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets or {};
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

  datasetPath = cfg.datasetPath or defaultDatasetPath;
  foundReplication = if datasetPath != null then findReplication datasetPath else null;
  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then ""
          else lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then foundReplication.replication.targetDataset
          else "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };

  resolvedImportDir = if cfg.importDir != null then cfg.importDir else "${cfg.dataDir}/import";

  envDir = "/run/teslamate";
  envFile = "${envDir}/env";


  extensionSpecType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Extension name";
      };

      schema = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional schema for CREATE EXTENSION";
      };

      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional extension version";
      };

      dropBeforeCreate = mkOption {
        type = types.bool;
        default = false;
        description = "Drop extension before creating it";
      };

      dropCascade = mkOption {
        type = types.bool;
        default = true;
        description = "Cascade when dropping the extension";
      };

      updateToLatest = mkOption {
        type = types.bool;
        default = false;
        description = "Run ALTER EXTENSION ... UPDATE";
      };
    };
  };

  schemaMigrationsType = types.submodule {
    options = {
      table = mkOption {
        type = types.str;
        default = "schema_migrations";
        description = "Migration table name";
      };

      column = mkOption {
        type = types.str;
        default = "version";
        description = "Column storing migration versions";
      };

      schema = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Schema containing the migrations table";
      };

      columnType = mkOption {
        type = types.str;
        default = "text";
        description = "Column type when ensureTable = true";
      };

      ensureTable = mkOption {
        type = types.bool;
        default = false;
        description = "Create the migrations table if it doesn't exist";
      };

      insertedAtColumn = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              default = "inserted_at";
              description = "Column name for inserted-at timestamps (Ecto compatibility).";
            };

            columnType = mkOption {
              type = types.str;
              default = "timestamptz";
              description = "SQL column type for inserted-at timestamps.";
            };

            defaultValue = mkOption {
              type = types.nullOr types.str;
              default = "CURRENT_TIMESTAMP";
              description = "Default SQL expression for inserted-at values (unquoted).";
            };

            notNull = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to mark the inserted-at column NOT NULL.";
            };
          };
        });
        default = null;
        description = "Optional inserted-at column definition for schema_migrations.";
      };

      pruneUnknown = mkOption {
        type = types.bool;
        default = false;
        description = "Delete rows not present in entries";
      };

      entries = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Versions that must exist";
      };
    };
  };
in
{
  options.modules.services.teslamate = {
    enable = mkEnableOption "TeslaMate self-hosted telemetry stack";

    image = mkOption {
      type = types.str;
      default = "teslamate/teslamate:2.2.0@sha256:db111162f1037a8c8ce6fe56e538a4432b8a34d3d6176916ba22d42ef7ee4b78";
      description = ''
        TeslaMate container image (pin to a specific tag or digest for reproducibility).
        Override this to track upstream releases and digests as needed.
      '';
      example = "teslamate/teslamate:1.32.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };

    user = mkOption {
      type = types.str;
      default = "teslamate";
      description = "System user that owns TeslaMate state and runs auxiliary jobs.";
    };

    group = mkOption {
      type = types.str;
      default = "teslamate";
      description = "Primary group for TeslaMate data.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/teslamate";
      description = "Base directory for TeslaMate state (import staging, grafana/mosquitto data).";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing TeslaMate data (used for auto-creation and replication).";
      example = "tank/services/teslamate";
    };

    importDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional override for the import directory mounted at /opt/app/import.";
    };

    timezone = mkOption {
      type = types.str;
      default = config.time.timeZone or "UTC";
      description = "TZ value passed to TeslaMate.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address to bind the TeslaMate HTTP listener to.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 4000;
      description = "Host port for TeslaMate (container listens on 4000 internally).";
    };

    resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = null;
      description = "Optional Podman resource limits for the TeslaMate container.";
    };

    podmanNetwork = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Attach TeslaMate to a named Podman network (defaults to host publishing).";
    };

    encryptionKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "SOPS-managed file containing the ENCRYPTION_KEY used for Tesla API tokens.";
    };

  database = {
      host = mkOption {
        type = types.str;
        default = "host.containers.internal";
        description = "Database host TeslaMate connects to (use host.containers.internal for local Postgres).";
      };
      port = mkOption {
        type = types.port;
        default = 5432;
        description = "Database port.";
      };
      name = mkOption {
        type = types.str;
        default = "teslamate";
        description = "Database name.";
      };
      user = mkOption {
        type = types.str;
        default = "teslamate";
        description = "Database role/owner.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the database password file (SOPS).";
      };
      manageDatabase = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically provision the PostgreSQL role/database via modules.services.postgresql.databases.";
      };
      localInstance = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to add dependencies on the local PostgreSQL service.";
      };
      extensions = mkOption {
        type = types.listOf (types.coercedTo types.str (name: { inherit name; }) extensionSpecType);
        default = [
          { name = "pgcrypto"; }
          { name = "cube"; dropBeforeCreate = true; dropCascade = true; updateToLatest = true; }
          { name = "earthdistance"; dropBeforeCreate = true; dropCascade = true; updateToLatest = true; }
        ];
        description = ''
          Extensions to enable when manageDatabase = true. Strings are coerced to `{ name = "ext"; }`.
          Structured entries allow controlling schema, drop/reinstall behavior, and updates.
        '';
      };

      schemaMigrations = mkOption {
        type = types.nullOr schemaMigrationsType;
        default = null;
        description = "Optional schema migrations seeding config passed through to the Postgres module.";
      };
    };

    mqtt = {
      enable = mkEnableOption "TeslaMate MQTT publishing" // { default = true; };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "MQTT broker host TeslaMate should publish to (typically the shared EMQX instance).";
      };
      port = mkOption {
        type = types.port;
        default = 1883;
        description = "MQTT broker port.";
      };
      username = mkOption {
        type = types.str;
        default = "teslamate";
        description = "MQTT username used by TeslaMate.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          SOPS-managed secret containing the MQTT password. Ensure the file is
          deployed with mode 0440 and owned by root:${cfg.group} (teslamate) so
          systemd LoadCredential can pass it into the container securely.
        '';
      };
    };

    grafanaIntegration = {
      enable = mkEnableOption "Publish TeslaMate dashboards into the shared Grafana instance" // { default = true; };
      folder = mkOption {
        type = types.str;
        default = "TeslaMate";
        description = "Grafana folder name where dashboards will be provisioned.";
      };
      datasourceName = mkOption {
        type = types.str;
        default = "TeslaMate";
        description = "Display name for the Postgres data source used by TeslaMate dashboards.";
      };
      datasourceUid = mkOption {
        type = types.str;
        default = "TeslaMate";
        description = "Grafana data source UID expected by the upstream dashboards.";
      };
      dashboardsPath = mkOption {
        type = types.path;
        default = defaultDashboardsPath;
        description = "Directory containing TeslaMate dashboard JSON files.";
      };
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for TeslaMate.";
    };

    metrics = mkOption {
      type = types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 4000;
        path = "/metrics";
        labels = {
          service = serviceName;
          service_type = "telemetry";
        };
      };
      description = "Prometheus scrape metadata for TeslaMate.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "telemetry";
        };
      };
      description = "Log shipping configuration for TeslaMate.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Restic backup policy for TeslaMate data directories.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "TeslaMate logger failed on ${config.networking.hostName}";
      };
      description = "Notification hooks for TeslaMate failures.";
    };

    preseed = {
      enable = mkEnableOption "automatic Restic/ZFS restore before first start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for preseed restores.";
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
        description = "Preferred restore method order.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.database.passwordFile != null;
            message = "modules.services.teslamate.database.passwordFile must be set.";
          }
          {
            assertion = cfg.encryptionKeyFile != null;
            message = "modules.services.teslamate.encryptionKeyFile must be provided.";
          }
          {
            assertion = (!cfg.mqtt.enable) || cfg.mqtt.passwordFile != null;
            message = "TeslaMate MQTT passwordFile is required whenever MQTT publishing is enabled.";
          }
          {
            assertion = !(cfg.grafanaIntegration.enable && !(config.modules.services.grafana.enable or false));
            message = "TeslaMate grafanaIntegration requires modules.services.grafana.enable.";
          }
        ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          description = "TeslaMate service account";
        };

        users.groups.${cfg.group} = {};

        systemd.tmpfiles.rules = [
          "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
          "d ${resolvedImportDir} 0750 ${cfg.user} ${cfg.group} -"
        ];

        modules.storage.datasets.services.${serviceName} = {
          mountpoint = cfg.dataDir;
          recordsize = "16K";
          compression = "zstd";
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        modules.services.postgresql.databases.${cfg.database.name} = mkIf cfg.database.manageDatabase {
          owner = cfg.database.user;
          ownerPasswordFile = cfg.database.passwordFile;
          extensions = cfg.database.extensions;
          permissionsPolicy = "owner-readwrite+readonly-select";
          schemaMigrations = cfg.database.schemaMigrations;
        };

        virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
          image = cfg.image;
          environmentFiles = [ envFile ];
          environment = {
            TZ = cfg.timezone;
            DATABASE_USER = cfg.database.user;
            DATABASE_NAME = cfg.database.name;
            DATABASE_HOST = cfg.database.host;
            DATABASE_PORT = toString cfg.database.port;
            MQTT_HOST = cfg.mqtt.host;
            MQTT_PORT = toString cfg.mqtt.port;
            MQTT_USERNAME = cfg.mqtt.username;
            DISABLE_MQTT = if cfg.mqtt.enable then "false" else "true";
            IMPORT_DIR = "/opt/app/import";
          };
          volumes = [
            "${resolvedImportDir}:/opt/app/import:rw"
          ];
          ports = [
            "${cfg.listenAddress}:${toString cfg.listenPort}:4000/tcp"
          ];
          resources = cfg.resources;
          extraOptions = [
            "--pull=newer"
          ] ++ lib.optionals (cfg.podmanNetwork != null) [
            "--network=${cfg.podmanNetwork}"
          ];
        };

  systemd.services.${serviceAttrName} = lib.mkMerge [
          {
            after = [ "network-online.target" ]
              ++ lib.optional (cfg.database.localInstance) "postgresql.service"
              ++ lib.optionals cfg.preseed.enable [ "teslamate-preseed.service" ];
            wants = [ "network-online.target" ]
              ++ lib.optionals cfg.preseed.enable [ "teslamate-preseed.service" ];
            requires = lib.optionals (cfg.database.manageDatabase && cfg.database.localInstance) [ "postgresql-provision-databases.service" ];
            serviceConfig = {
              LoadCredential =
                [
                  "db_password:${cfg.database.passwordFile}"
                  "encryption_key:${cfg.encryptionKeyFile}"
                ]
                ++ lib.optionals cfg.mqtt.enable [
                  "mqtt_password:${cfg.mqtt.passwordFile}"
                ];
              Restart = lib.mkForce "on-failure";
              RestartSec = "10s";
            };
            preStart = ''
              set -euo pipefail
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${resolvedImportDir}
              install -d -m 700 ${envDir}
              tmp="${envFile}.tmp"
              trap 'rm -f "$tmp"' EXIT
              {
                printf "DATABASE_PASS=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/db_password")"
                printf "ENCRYPTION_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/encryption_key")"
                ${lib.optionalString cfg.mqtt.enable ''
                printf "MQTT_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/mqtt_password")"
                ''}
              } > "$tmp"
              install -m 600 "$tmp" ${envFile}
            '';
          }
          (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
            unitConfig.OnFailure = [ "notify@teslamate-failure:%n.service" ];
          })
        ];

        modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          "teslamate-failure" = {
            enable = true;
            priority = "high";
            title = "❌ TeslaMate service failed";
            body = ''
<b>Host:</b> ${config.networking.hostName}
<b>Service:</b> podman-teslamate

Check logs: <code>journalctl -u ${mainServiceUnit} -n 200</code>
'';
          };
        };

        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          teslamate = {
            enable = true;
            repository = cfg.backup.repository;
            frequency = cfg.backup.frequency;
            retention = cfg.backup.retention;
            paths = if cfg.backup.paths != [] then cfg.backup.paths else [ cfg.dataDir ];
            excludePatterns = cfg.backup.excludePatterns;
            useSnapshots = cfg.backup.useSnapshots or true;
            zfsDataset = cfg.backup.zfsDataset or datasetPath;
            tags = cfg.backup.tags;
          };
        };

        modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) (
          let
            defaultBackend = {
              scheme = "http";
              host = cfg.listenAddress;
              port = cfg.listenPort;
            };
            configuredBackend = cfg.reverseProxy.backend or {};
          in {
            enable = true;
            hostName = cfg.reverseProxy.hostName;
            backend = lib.recursiveUpdate defaultBackend configuredBackend;
            auth = cfg.reverseProxy.auth;
            authelia = cfg.reverseProxy.authelia;
            security = cfg.reverseProxy.security;
            extraConfig = cfg.reverseProxy.extraConfig;
          }
        );

        modules.services.authelia.accessControl.declarativelyProtectedServices.${serviceName} = mkIf (
          config.modules.services.authelia.enable or false
          && cfg.reverseProxy != null && cfg.reverseProxy.enable
          && cfg.reverseProxy.authelia != null && cfg.reverseProxy.authelia.enable
        ) (let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (group: "group:${group}") (authCfg.allowedGroups or []);
          bypassResources =
            (map (path: "^${lib.escapeRegex path}.*") (authCfg.bypassPaths or []))
            ++ (authCfg.bypassResources or []);
        });

  modules.alerting.rules."teslamate-service-down" = {
          type = "promql";
          alertname = "TeslaMateServiceInactive";
          expr = ''container_service_active{service="teslamate"} == 0'';
          for = "2m";
          severity = "high";
          labels = { service = serviceName; category = "telemetry"; };
          annotations = {
            summary = "TeslaMate is down on {{ $labels.instance }}";
            description = "TeslaMate container is not running";
            command = "systemctl status ${mainServiceUnit}";
          };
        };

        modules.services.grafana.integrations.teslamate = mkIf (cfg.grafanaIntegration.enable) {
          datasources.teslamate = {
            name = cfg.grafanaIntegration.datasourceName;
            uid = cfg.grafanaIntegration.datasourceUid;
            type = "postgres";
            access = "proxy";
            url = "${cfg.database.host}:${toString cfg.database.port}";
            user = cfg.database.user;
            database = cfg.database.name;
            jsonData = {
              sslmode = "disable";
              timescaledb = false;
            };
            secureJsonData = {
              password = "$__file{${grafanaCredentialPath}}";
            };
          };
          dashboards = {
            teslamate = {
              name = "TeslaMate Dashboards";
              folder = cfg.grafanaIntegration.folder;
              path = cfg.grafanaIntegration.dashboardsPath;
            };
          };
          loadCredentials = [ "${grafanaCredentialName}:${cfg.database.passwordFile}" ];
        };
      }
    )



    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = replicationConfig;
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
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
