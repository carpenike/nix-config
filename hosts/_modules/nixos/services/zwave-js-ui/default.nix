{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkDefault
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    optionalString
    types;

  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit lib pkgs; };

  cfg = config.modules.services."zwave-js-ui";
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "zwave-js-ui";
  serviceUnit = "${serviceName}.service";
  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";
  storeRoot = cfg.dataDir;
  configDbPath = "${storeRoot}/.config-db";
  runtimeEnvPath = "${cfg.dataDir}/.zwavejs-env";
  settingsPath = "${cfg.dataDir}/settings.json";
  dataDirUnderVarLib = lib.hasPrefix "/var/lib/" cfg.dataDir;
  stateDirectoryName = if dataDirUnderVarLib then lib.removePrefix "/var/lib/" cfg.dataDir else null;

  credentialItems = lib.filter (entry: entry != null) [
    (if cfg.security.sessionSecretFile != null then {
      name = "session_secret";
      path = cfg.security.sessionSecretFile;
      envVar = "SESSION_SECRET";
      jsonPath = null;
    } else null)
    (if cfg.security.s0LegacyKeyFile != null then {
      name = "s0_key";
      path = cfg.security.s0LegacyKeyFile;
      envVar = "KEY_S0_Legacy";
      jsonPath = [ "zwave" "securityKeys" "S0_Legacy" ];
    } else null)
    (if cfg.security.s2UnauthenticatedKeyFile != null then {
      name = "s2_unauth";
      path = cfg.security.s2UnauthenticatedKeyFile;
      envVar = "KEY_S2_Unauthenticated";
      jsonPath = [ "zwave" "securityKeys" "S2_Unauthenticated" ];
    } else null)
    (if cfg.security.s2AuthenticatedKeyFile != null then {
      name = "s2_auth";
      path = cfg.security.s2AuthenticatedKeyFile;
      envVar = "KEY_S2_Authenticated";
      jsonPath = [ "zwave" "securityKeys" "S2_Authenticated" ];
    } else null)
    (if cfg.security.s2AccessControlKeyFile != null then {
      name = "s2_access";
      path = cfg.security.s2AccessControlKeyFile;
      envVar = "KEY_S2_AccessControl";
      jsonPath = [ "zwave" "securityKeys" "S2_AccessControl" ];
    } else null)
    (if cfg.security.s2LongRangeKeyFile != null then {
      name = "s2_lr";
      path = cfg.security.s2LongRangeKeyFile;
      envVar = "KEY_LR_S2_Authenticated";
      jsonPath = [ "zwave" "securityKeysLongRange" "S2_Authenticated" ];
    } else null)
    (if cfg.security.s2LongRangeAccessControlKeyFile != null then {
      name = "s2_lr_access";
      path = cfg.security.s2LongRangeAccessControlKeyFile;
      envVar = "KEY_LR_S2_AccessControl";
      jsonPath = [ "zwave" "securityKeysLongRange" "S2_AccessControl" ];
    } else null)
  ];

  securityCredentialItems = lib.filter (entry: (entry.jsonPath or null) != null) credentialItems;
  securityMappingsJson = builtins.toJSON (map (entry: {
    envVar = entry.envVar;
    path = entry.jsonPath;
  }) securityCredentialItems);

  loadCredentialEntries = map (entry: "${entry.name}:${toString entry.path}") credentialItems;
  needsRuntimeEnv = credentialItems != [ ];

  notificationsTemplateName = "${serviceName}-failure";

  tzEnv = if (config.time.timeZone or null) != null then [ "TZ=${config.time.timeZone}" ] else [ ];
  baseEnvironment =
    tzEnv
    ++ [
      "PORT=${toString cfg.ui.port}"
      "HOST=${cfg.ui.listenAddress}"
      "STORE_DIR=${storeRoot}"
      "ZWAVEJS_EXTERNAL_CONFIG=${configDbPath}"
    ]
    ++ lib.optional (cfg.serial.device != null) "ZWAVEJS_SERIAL_PORT=${cfg.serial.device}"
    # Express-based UI must trust proxy headers when fronted by Caddy; otherwise
    # rate limiting misinterprets X-Forwarded-For and errors loudly. See
    # https://express-rate-limit.github.io/ERR_ERL_UNEXPECTED_X_FORWARDED_FOR
    ++ lib.optional (cfg.reverseProxy != null && cfg.reverseProxy.enable) "TRUST_PROXY=true";

  mqttAclTopics =
    if cfg.mqtt.allowedTopics != [ ] then cfg.mqtt.allowedTopics else [ "${cfg.mqtt.baseTopic}/#" ];

  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets or { };
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

  foundReplication =
    if config.modules.backup.sanoid.enable or false then
      findReplication datasetPath
    else
      null;

  replicationConfig =
    if foundReplication == null then null else
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
  options.modules.services."zwave-js-ui" = {
    enable = mkEnableOption "Z-Wave JS UI (zwavejs2mqtt) service wrapper";

    package = mkOption {
      type = types.package;
      default = pkgs.zwave-js-ui;
      description = "Package used to run Z-Wave JS UI.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/zwave-js-ui";
      description = "Persistent data directory managed via ZFS.";
    };

    user = mkOption {
      type = types.str;
      default = "zwave-js-ui";
      description = "System user running the service.";
    };

    group = mkOption {
      type = types.str;
      default = "zwave-js-ui";
      description = "Primary group used for service state.";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "dialout" ];
      description = "Extra groups assigned to the service user (dialout recommended for USB adapters).";
    };

    serial = {
      device = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Serial adapter path such as /dev/serial/by-id/... or tcp://host:port.";
      };
    };

    zwave = {
      serverPort = mkOption {
        type = types.port;
        default = 3000;
        description = "WebSocket server port exposed to Home Assistant.";
      };
    };

    ui = {
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address for the HTTP UI listener (reverse proxy targets this).";
      };
      port = mkOption {
        type = types.port;
        default = 8091;
        description = "HTTP UI port.";
      };
      urlPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional URL prefix when the UI is served behind a reverse proxy (e.g., /zwave).";
      };
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for the UI.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnit;
        labels = {
          service = serviceName;
          service_type = "automation";
        };
      };
      description = "Log shipping configuration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        frequency = mkDefault "daily";
        tags = mkDefault [ "zwave" serviceName "automation" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        excludePatterns = mkDefault [ "**/log/**" "**/tmp/**" ];
      };
      description = "Backup policy for Z-Wave controller state.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "automation-alerts" ];
        customMessages.failure = "Z-Wave JS UI failed on ${config.networking.hostName}";
      };
      description = "Notification routing for service failures.";
    };

    mqtt = {
      enable = mkEnableOption "Integrate with MQTT/EMQX for command bridging" // { default = false; };
      baseTopic = mkOption {
        type = types.str;
        default = "zwave";
        description = "Root MQTT topic advertised by Z-Wave JS UI.";
      };
      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "MQTT username provisioned in EMQX.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret containing the MQTT password.";
      };
      registerEmqxIntegration = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically register MQTT credentials with the EMQX module.";
      };
      allowedTopics = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Explicit MQTT topics to allow when creating ACLs (defaults to baseTopic/#).";
      };
    };

    security = {
      sessionSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret that seeds SESSION_SECRET for the UI.";
      };
      s0LegacyKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file containing the S0 legacy key (hex).";
      };
      s2UnauthenticatedKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file for the S2 unauthenticated key (hex).";
      };
      s2AuthenticatedKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file for the S2 authenticated key (hex).";
      };
      s2AccessControlKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file for the S2 access control key (hex).";
      };
      s2LongRangeKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file for the S2 long-range authenticated key (hex).";
      };
      s2LongRangeAccessControlKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret file for the S2 long-range access control key (hex).";
      };
    };

    preseed = {
      enable = mkEnableOption "automatic dataset restore before the service starts";
      repositoryUrl = mkOption {
        type = types.str;
        description = "Restic repository URL containing controller backups.";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to the Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., cloud credentials).";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered restore strategies attempted during preseed.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable (
      let
        caddyBackend = {
          scheme = "http";
          host = cfg.ui.listenAddress;
          port = cfg.ui.port;
        };
      in
      {
        assertions = [
          {
            assertion = !(cfg.mqtt.enable && cfg.mqtt.username == null);
            message = "mqtt.username must be set when mqtt.enable = true.";
          }
          {
            assertion = !(cfg.mqtt.enable && cfg.mqtt.passwordFile == null && cfg.mqtt.registerEmqxIntegration);
            message = "Provide mqtt.passwordFile when registering credentials with EMQX.";
          }
          {
            assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
            message = "preseed.repositoryUrl is required when preseed.enable = true.";
          }
          {
            assertion = !cfg.preseed.enable || cfg.preseed.passwordFile != null;
            message = "preseed.passwordFile is required when preseed.enable = true.";
          }
        ];

        modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = caddyBackend;
          auth = cfg.reverseProxy.auth;
          authelia = cfg.reverseProxy.authelia;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        modules.services.authelia.accessControl.declarativelyProtectedServices.${serviceName} = mkIf (
          (config.modules.services.authelia.enable or false)
          && cfg.reverseProxy != null
          && cfg.reverseProxy.enable
          && cfg.reverseProxy.authelia != null
          && cfg.reverseProxy.authelia.enable
        ) (
          let
            authCfg = cfg.reverseProxy.authelia;
            bypassPaths = authCfg.bypassPaths or [ ];
            bypassResources = authCfg.bypassResources or [ ];
          in
          {
            domain = cfg.reverseProxy.hostName;
            policy = authCfg.policy;
            subject = map (group: "group:${group}") (authCfg.allowedGroups or [ ]);
            bypassResources =
              (map (path: "^${lib.escapeRegex path}/.*$") bypassPaths)
              ++ bypassResources;
          }
        );

        modules.services.emqx.integrations.${serviceName} = mkIf (
          cfg.mqtt.enable
          && cfg.mqtt.registerEmqxIntegration
          && cfg.mqtt.username != null
          && cfg.mqtt.passwordFile != null
        ) {
          users = [
            {
              username = cfg.mqtt.username;
              passwordFile = cfg.mqtt.passwordFile;
              tags = [ serviceName "zwave" ];
            }
          ];
          acls = [
            {
              permission = "allow";
              action = "pubsub";
              subject = {
                kind = "user";
                value = cfg.mqtt.username;
              };
              topics = mqttAclTopics;
              comment = "Z-Wave JS UI publishes device state and consumes commands.";
            }
          ];
        };

        modules.storage.datasets.services.${serviceName} =
          let
            baseDataset = {
              mountpoint = cfg.dataDir;
              recordsize = "16K";
              compression = "zstd";
              properties = { "com.sun:auto-snapshot" = "true"; };
            };
            permissionAttrs =
              if dataDirUnderVarLib then
                { }
              else
                {
                  owner = cfg.user;
                  group = cfg.group;
                  mode = "0750";
                };
          in
          baseDataset // permissionAttrs;

        modules.backup.restic.jobs.${serviceName} = mkIf (cfg.backup != null && cfg.backup.enable) {
          enable = true;
          repository = cfg.backup.repository;
          frequency = cfg.backup.frequency;
          tags = cfg.backup.tags;
          paths = [ cfg.dataDir ];
          excludePatterns = cfg.backup.excludePatterns;
          useSnapshots = cfg.backup.useSnapshots;
          zfsDataset = cfg.backup.zfsDataset;
        };

        networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.ui.port ];

        users.groups.${cfg.group} = { };
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = mkForce "/var/empty";
          createHome = mkForce false;
          extraGroups = lib.unique cfg.extraGroups;
        };

        modules.notifications.templates.${notificationsTemplateName} = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          enable = true;
          priority = cfg.notifications.priority or "high";
          title = cfg.notifications.title or "❌ Z-Wave JS UI failure";
          body = cfg.notifications.body or ''
<b>Host:</b> ${config.networking.hostName}
<b>Service:</b> ${serviceUnit}

Inspect logs with <code>journalctl -u ${serviceUnit} -n 200</code>.
'';
        };

        systemd.services.${serviceName} = mkMerge [
          {
            description = "Z-Wave JS UI";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-${serviceName}.service";
            wants = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-${serviceName}.service";
            serviceConfig = mkMerge [
              {
                ExecStart = mkForce "${cfg.package}/bin/zwave-js-ui";
                Restart = "on-failure";
                RestartSec = "5s";
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = cfg.dataDir;
                PermissionsStartOnly = true;
                UMask = "0027";
                SupplementaryGroups = lib.unique cfg.extraGroups;
                Environment = baseEnvironment;
                ReadWritePaths = [ cfg.dataDir ];
              }
              (mkIf dataDirUnderVarLib {
                StateDirectory = stateDirectoryName;
                StateDirectoryMode = "0750";
              })
              (mkIf needsRuntimeEnv {
                EnvironmentFile = [ "-${runtimeEnvPath}" ];
                LoadCredential = loadCredentialEntries;
              })
            ];
            preStart = lib.mkAfter ''
              set -euo pipefail
              ${optionalString (cfg.serial.device != null) ''
                ${pkgs.systemd}/bin/udevadm settle --exit-if-exists=${lib.escapeShellArg cfg.serial.device}
              ''}
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${configDbPath}
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}/store
              ${optionalString needsRuntimeEnv ''
                envFile=${lib.escapeShellArg runtimeEnvPath}
                : > "$envFile"
                chmod 600 "$envFile"
                chown ${cfg.user}:${cfg.group} "$envFile"
                ${lib.concatMapStrings (entry: ''
                  if [ -f "$CREDENTIALS_DIRECTORY/${entry.name}" ]; then
                    value="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${entry.name}")"
                    printf '%s=%s\n' ${lib.escapeShellArg entry.envVar} "$value" >> "$envFile"
                  fi
                '') credentialItems}
                ${optionalString (securityCredentialItems != [ ]) ''
                  settingsFile=${lib.escapeShellArg settingsPath}
                  if [ -s "$envFile" ]; then
                    ${pkgs.python3}/bin/python3 - "$settingsFile" "$envFile" ${lib.escapeShellArg securityMappingsJson} <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]
env_file = sys.argv[2]
mapping = json.loads(sys.argv[3])

env_values = {}
try:
    with open(env_file, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env_values[key] = value
except FileNotFoundError:
    sys.exit(0)

if not any(env_values.get(entry["envVar"]) for entry in mapping):
    sys.exit(0)

if os.path.exists(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as existing:
            data = json.load(existing)
    except json.JSONDecodeError:
        data = {}
else:
    data = {}

def ensure_parent(root, path):
    current = root
    for key in path[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            child = {}
            current[key] = child
        current = child
    return current

changed = False
for entry in mapping:
    value = env_values.get(entry["envVar"])
    if not value:
        continue
    parent = ensure_parent(data, entry["path"])
    leaf = entry["path"][-1]
    if parent.get(leaf) != value:
        parent[leaf] = value
        changed = True

if changed:
    tmp_path = settings_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    os.replace(tmp_path, settings_path)
PY
                    if [ -f "$settingsFile" ]; then
                      chown ${cfg.user}:${cfg.group} "$settingsFile"
                      chmod 640 "$settingsFile"
                    fi
                  fi
                ''}
              ''}
                settingsFile=${lib.escapeShellArg settingsPath}
                ${pkgs.python3}/bin/python3 - "$settingsFile" ${lib.escapeShellArg (cfg.serial.device or "")} ${lib.escapeShellArg (builtins.toString cfg.zwave.serverPort)} <<'PY'
        import json
        import os
        import sys

        settings_path = sys.argv[1]
        serial_port = sys.argv[2]
        server_port = int(sys.argv[3])

        if os.path.exists(settings_path):
          try:
            with open(settings_path, encoding="utf-8") as existing:
              data = json.load(existing)
          except json.JSONDecodeError:
            data = {}
        else:
          data = {}

        zwave_cfg = data.setdefault("zwave", {})
        changed = False

        if serial_port:
          if zwave_cfg.get("port") != serial_port:
            zwave_cfg["port"] = serial_port
            changed = True

        if zwave_cfg.get("serverPort") != server_port:
          zwave_cfg["serverPort"] = server_port
          changed = True

        if changed:
          tmp_path = settings_path + ".tmp"
          with open(tmp_path, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2)
            out.write("\n")
          os.replace(tmp_path, settings_path)
        PY
                if [ -f "$settingsFile" ]; then
                chown ${cfg.user}:${cfg.group} "$settingsFile"
                chmod 640 "$settingsFile"
                fi
            '';
          }
          (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
            unitConfig.OnFailure = [ "notify@${notificationsTemplateName}:%n.service" ];
          })
        ];
      }
    ))

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnit;
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
