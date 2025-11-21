{ config, lib, pkgs, ... }:
let
  inherit (lib)
    literalExpression
    mkDefault
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    optionalString
    types;

  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit lib pkgs; };

  cfg = config.modules.services.zigbee2mqtt;
  notificationsCfg = config.modules.notifications;
  hasCentralizedNotifications = notificationsCfg.enable or false;

  serviceName = "zigbee2mqtt";
  serviceUnit = "${serviceName}.service";
  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  secretFileName = "secret.yaml";
  secretFilePath = "${cfg.dataDir}/${secretFileName}";

  credentialItems = lib.filter (entry: entry != null) [
    (if cfg.mqtt.passwordFile != null then { name = "mqtt_password"; path = cfg.mqtt.passwordFile; } else null)
    (if cfg.frontend.authTokenFile != null then { name = "frontend_token"; path = cfg.frontend.authTokenFile; } else null)
    (if cfg.advanced.networkKeyFile != null then { name = "network_key"; path = cfg.advanced.networkKeyFile; } else null)
    (if cfg.advanced.panIdFile != null then { name = "pan_id"; path = cfg.advanced.panIdFile; } else null)
    (if cfg.advanced.extPanIdFile != null then { name = "ext_pan_id"; path = cfg.advanced.extPanIdFile; } else null)
  ];
  loadCredentialEntries = map (entry: "${entry.name}:${toString entry.path}") credentialItems;
  needsSecretFile = credentialItems != [];
  needsRuntimeEnv = cfg.advanced.panIdFile != null || cfg.advanced.extPanIdFile != null;
  runtimeEnvPath = "${cfg.dataDir}/.zigbee2mqtt-env";

  sanitizeAttrs = attrs: lib.filterAttrs (_: value: value != null && value != [ ] && value != { }) attrs;

  # Recursively locate replication configuration so preseed restores can reuse
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
  options.modules.services.zigbee2mqtt = {
    enable = mkEnableOption "Zigbee2MQTT service wrapper";

    package = mkOption {
      type = types.package;
      default = pkgs.zigbee2mqtt;
      description = "Package used to run Zigbee2MQTT.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/zigbee2mqtt";
      description = "Persistent data directory that will be backed by ZFS.";
    };

    user = mkOption {
      type = types.str;
      default = "zigbee2mqtt";
      description = "System user running Zigbee2MQTT.";
    };

    group = mkOption {
      type = types.str;
      default = "zigbee2mqtt";
      description = "Primary group for Zigbee2MQTT state.";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ "dialout" ];
      description = "Extra groups assigned to the Zigbee2MQTT user (dialout required for USB adapters).";
    };

    permitJoin = mkOption {
      type = types.bool;
      default = false;
      description = "Whether new Zigbee devices can join the network without manual enablement.";
    };

    serial = {
      port = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''Serial adapter location. Accepts `/dev/serial/by-id/...` or TCP controllers like `tcp://10.30.100.183:6638`.'';
      };
      adapter = mkOption {
        type = types.nullOr types.str;
        default = "zstack";
        description = "Adapter firmware type (e.g., zstack, ezsp, deconz).";
      };
      baudrate = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Optional baudrate override for USB-based adapters.";
      };
      rtscts = mkOption {
        type = types.bool;
        default = false;
        description = "Enable RTS/CTS hardware flow control on the serial adapter.";
      };
      adapterDelay = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Adapter delay for ConBee/RaspBee devices (milliseconds).";
      };
      advanced = {
        disableLed = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Disable the coordinator status LED (where supported).";
        };
        transmitPower = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Override coordinator transmit power (dBm) via the serial advanced settings.";
        };
      };
    };

    mqtt = {
      server = mkOption {
        type = types.str;
        default = "mqtt://localhost:1883";
        description = "MQTT broker URL (supports mqtt:// and mqtts://).";
      };
      baseTopic = mkOption {
        type = types.str;
        default = "zigbee2mqtt";
        description = "Root MQTT topic used by Zigbee2MQTT.";
      };
      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "MQTT username (optional when broker allows anonymous auth).";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret containing the MQTT password. Copied into secret.yaml at runtime.";
      };
      registerEmqxIntegration = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically register credentials and ACLs with the EMQX integration module.";
      };
      allowedTopics = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Explicit MQTT topics to allow when registering with EMQX. Defaults to the base topic tree.";
      };
      rejectUnauthorized = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to verify TLS certificates presented by the MQTT broker.";
      };
      keepalive = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Optional MQTT keepalive interval (seconds).";
      };
      protocolVersion = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Optional MQTT protocol version override (e.g., 3, 4, or 5).";
      };
      includeDeviceInformation = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Whether to include device information payloads alongside state updates.";
      };
      caFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional CA certificate for TLS connections.";
      };
      certFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Client certificate for mutual TLS authentication.";
      };
      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Client key for mutual TLS authentication.";
      };
    };

    frontend = {
      enable = mkEnableOption "Zigbee2MQTT frontend" // { default = true; };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address the web UI listens on (Caddy reverse proxy targets this).";
      };
      port = mkOption {
        type = types.port;
        default = 8080;
        description = "Frontend HTTP port.";
      };
      urlPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional URL path prefix when served behind a reverse proxy (e.g., /zigbee).";
      };
      authTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed secret containing the frontend auth token. Written to secret.yaml when provided.";
      };
    };

    homeAssistant = {
      enable = mkEnableOption "Home Assistant MQTT discovery" // { default = true; };
      discoveryTopic = mkOption {
        type = types.str;
        default = "homeassistant";
        description = "Home Assistant discovery topic.";
      };
      legacyEntityAttributes = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to expose legacy entity attributes (only needed for old HA releases).";
      };
    };

    advanced = {
      logLevel = mkOption {
        type = types.enum [ "trace" "debug" "info" "warn" "error" ];
        default = "info";
        description = "Zigbee2MQTT log verbosity.";
      };
      cacheState = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to cache device state and re-publish on restart.";
      };
      legacyApi = mkOption {
        type = types.bool;
        default = false;
        description = "Expose the legacy API endpoints.";
      };
      transmitPower = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Override coordinator transmit power (dBm).";
      };
      networkKey = mkOption {
        type = types.oneOf [ types.str (types.listOf types.int) ];
        default = "GENERATE";
        description = "Zigbee network key (string or list of ints). Leave GENERATE to auto-create.";
      };
      networkKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed file containing the Zigbee network key (YAML content written into secret.yaml).";
      };
      panId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Custom PAN ID (hex).";
      };
      panIdFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed file containing the PAN ID (written to secret.yaml when provided).";
      };
      extPanId = mkOption {
        type = types.nullOr (types.listOf types.int);
        default = null;
        description = "Extended PAN ID (list of ints).";
      };
      extPanIdFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "SOPS-managed file with the extended PAN ID (YAML list).";
      };
      availabilityBlocklist = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of devices excluded from availability payloads.";
      };
      channel = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Override Zigbee network channel (11-26).";
      };
      homeassistantLegacyEntityAttributes = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Mirror `advanced.homeassistant_legacy_entity_attributes`. Leave null to use Zigbee2MQTT defaults.";
      };
      homeassistantLegacyTriggers = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Mirror `advanced.homeassistant_legacy_triggers`.";
      };
      homeassistantStatusTopic = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Custom Home Assistant status topic string.";
      };
      lastSeen = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Control `advanced.last_seen` formatting (e.g., ISO_8601).";
      };
      legacyAvailabilityPayload = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Set `advanced.legacy_availability_payload`.";
      };
      logOutput = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Override `advanced.log_output` (leave empty to use default).";
      };
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for the Zigbee2MQTT web UI.";
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
        tags = mkDefault [ "zigbee" serviceName "automation" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        excludePatterns = mkDefault [ "**/log/**" "**/tmp/**" ];
      };
      description = "Backup policy for Zigbee2MQTT state.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = { onFailure = [ "automation-alerts" ]; };
        customMessages = {
          failure = "Zigbee2MQTT failed on ${config.networking.hostName}";
        };
      };
      description = "Notification routing for failures.";
    };

    preseed = {
      enable = mkEnableOption "automatic dataset restore before Zigbee2MQTT starts";
      repositoryUrl = mkOption {
        type = types.str;
        description = "Restic repository URL containing Zigbee2MQTT backups.";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to the Restic password file.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., B2 credentials).";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered list of restore mechanisms to attempt.";
      };
    };

    devicesFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional external devices file (same semantics as Zigbee2MQTT's `devices` setting).";
      example = "devices.yaml";
    };

    groupsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional external groups file referenced from configuration.yaml.";
      example = "groups.yaml";
    };

    extraSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Raw Zigbee2MQTT settings merged on top of the managed configuration.";
      example = literalExpression ''{
        experimental = { new_api = true; };
      }'';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable (
      let
        resolveDataFile = file:
          if file == null then null else if lib.hasPrefix "/" file then file else "${cfg.dataDir}/${file}";

        mqttSettings = sanitizeAttrs (
          {
            base_topic = cfg.mqtt.baseTopic;
            server = cfg.mqtt.server;
          }
          // optionalAttrs (cfg.mqtt.username != null) { user = cfg.mqtt.username; }
          // optionalAttrs (cfg.mqtt.passwordFile != null) { password = "!secret mqtt_password"; }
          // {
            ca = cfg.mqtt.caFile;
            key = cfg.mqtt.keyFile;
            cert = cfg.mqtt.certFile;
            reject_unauthorized = cfg.mqtt.rejectUnauthorized;
            keepalive = cfg.mqtt.keepalive;
            version = cfg.mqtt.protocolVersion;
            include_device_information = cfg.mqtt.includeDeviceInformation;
          }
        );

        serialAdvancedSettings = sanitizeAttrs {
          disable_led = cfg.serial.advanced.disableLed;
          transmit_power = cfg.serial.advanced.transmitPower;
        };

        serialSettings =
          sanitizeAttrs {
            port = cfg.serial.port;
            adapter = cfg.serial.adapter;
            baudrate = cfg.serial.baudrate;
            rtscts = cfg.serial.rtscts;
            adapter_delay = cfg.serial.adapterDelay;
          }
          // optionalAttrs (serialAdvancedSettings != { }) { advanced = serialAdvancedSettings; };

        mqttAclTopics =
          let
            defaultTopics = [ "${cfg.mqtt.baseTopic}/#" ]
              ++ lib.optional cfg.homeAssistant.enable "${cfg.homeAssistant.discoveryTopic}/#";
          in
          if cfg.mqtt.allowedTopics != [ ] then cfg.mqtt.allowedTopics else defaultTopics;

        frontendSettings = optionalAttrs cfg.frontend.enable (
          sanitizeAttrs (
            {
              host = cfg.frontend.listenAddress;
              port = cfg.frontend.port;
              url = cfg.frontend.urlPath;
            }
            // optionalAttrs (cfg.frontend.authTokenFile != null) { auth_token = "!secret frontend_token"; }
          )
        );

        homeAssistantSettings = optionalAttrs cfg.homeAssistant.enable {
          homeassistant = sanitizeAttrs {
            enabled = true;
            discovery_topic = cfg.homeAssistant.discoveryTopic;
            legacy_entity_attributes = cfg.homeAssistant.legacyEntityAttributes;
          };
        };

        devicesSetting = cfg.devicesFile;
        groupsSetting = cfg.groupsFile;
        devicesFilePath = resolveDataFile cfg.devicesFile;
        groupsFilePath = resolveDataFile cfg.groupsFile;

        advancedSettings = sanitizeAttrs {
            log_level = cfg.advanced.logLevel;
            cache_state = cfg.advanced.cacheState;
            legacy_api = cfg.advanced.legacyApi;
            transmit_power = cfg.advanced.transmitPower;
            network_key =
              if cfg.advanced.networkKeyFile != null then
                "!secret network_key"
              else
                cfg.advanced.networkKey;
            pan_id =
              if cfg.advanced.panIdFile != null then
                null
              else
                cfg.advanced.panId;
            ext_pan_id =
              if cfg.advanced.extPanIdFile != null then
                null
              else
                cfg.advanced.extPanId;
            availability_blocklist = cfg.advanced.availabilityBlocklist;
            channel = cfg.advanced.channel;
            homeassistant_legacy_entity_attributes = cfg.advanced.homeassistantLegacyEntityAttributes;
            homeassistant_legacy_triggers = cfg.advanced.homeassistantLegacyTriggers;
            homeassistant_status_topic = cfg.advanced.homeassistantStatusTopic;
            last_seen = cfg.advanced.lastSeen;
            legacy_availability_payload = cfg.advanced.legacyAvailabilityPayload;
            log_output = cfg.advanced.logOutput;
          };

        baseSettings =
          homeAssistantSettings
          // {
            permit_join = cfg.permitJoin;
            mqtt = mqttSettings;
            serial = serialSettings;
          }
          // optionalAttrs (devicesSetting != null) { devices = devicesSetting; }
          // optionalAttrs (groupsSetting != null) { groups = groupsSetting; }
          // optionalAttrs cfg.frontend.enable { frontend = frontendSettings; }
          // optionalAttrs needsSecretFile { secret = secretFileName; }
          // optionalAttrs true { advanced = advancedSettings; };

        mergedSettings = lib.recursiveUpdate baseSettings cfg.extraSettings;

        caddyBackend = {
          scheme = "http";
          host = cfg.frontend.listenAddress;
          port = cfg.frontend.port;
        };
      in
      {
        assertions = [
          {
            assertion = cfg.serial.port != null;
            message = "modules.services.zigbee2mqtt.serial.port must be set (use tcp:// or /dev/serial path).";
          }
          {
            assertion = cfg.mqtt.server != "";
            message = "modules.services.zigbee2mqtt.mqtt.server cannot be empty.";
          }
          {
            assertion = !(cfg.mqtt.passwordFile != null && cfg.mqtt.username == null);
            message = "MQTT username must be provided when passwordFile is set.";
          }
          {
            assertion = !(cfg.advanced.panId != null && cfg.advanced.panIdFile != null);
            message = "Set either advanced.panId or advanced.panIdFile, not both.";
          }
          {
            assertion = !(cfg.advanced.extPanId != null && cfg.advanced.extPanIdFile != null);
            message = "Set either advanced.extPanId or advanced.extPanIdFile, not both.";
          }
          {
            assertion = !(cfg.advanced.networkKeyFile != null && cfg.advanced.networkKey != "GENERATE");
            message = "Use advanced.networkKeyFile or override advanced.networkKey (set it back to GENERATE when supplying a secret file).";
          }
          {
            assertion = !(cfg.frontend.authTokenFile != null && !cfg.frontend.enable);
            message = "Frontend auth token file requires the frontend to be enabled.";
          }
        ];

        services.zigbee2mqtt = {
          enable = true;
          package = cfg.package;
          dataDir = cfg.dataDir;
          settings = mergedSettings;
        };

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
          (config.modules.services.authelia.enable or false) &&
          cfg.reverseProxy != null &&
          cfg.reverseProxy.enable &&
          cfg.reverseProxy.authelia != null &&
          cfg.reverseProxy.authelia.enable
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
          cfg.mqtt.registerEmqxIntegration &&
          cfg.mqtt.username != null &&
          cfg.mqtt.passwordFile != null
        ) {
          users = [
            {
              username = cfg.mqtt.username;
              passwordFile = cfg.mqtt.passwordFile;
              tags = [ serviceName "zigbee" ];
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
              comment = "${serviceName} publishes device state and consumes actions";
            }
          ];
        };

        modules.storage.datasets.services.${serviceName} = {
          mountpoint = cfg.dataDir;
          recordsize = "16K";
          compression = "zstd";
          properties = { "com.sun:auto-snapshot" = "true"; };
        };

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

        networking.firewall.interfaces.lo.allowedTCPPorts =
          [ cfg.frontend.port ];

        users.groups.${cfg.group} = { };

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = mkForce "/var/empty";
          createHome = mkForce false;
          extraGroups = lib.unique cfg.extraGroups;
        };

        modules.notifications.templates."${serviceName}-failure" = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          enable = true;
          priority = cfg.notifications.priority or "high";
          title = cfg.notifications.title or "❌ Zigbee2MQTT service failed";
          body = cfg.notifications.body or ''
<b>Host:</b> ${config.networking.hostName}
<b>Service:</b> ${serviceUnit}

Run: <code>journalctl -u ${serviceUnit} -n 200</code>
'';
        };

        systemd.services.${serviceName} = mkMerge [
          {
            after = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-${serviceName}.service";
            wants = [ "network-online.target" ] ++ lib.optional cfg.preseed.enable "preseed-${serviceName}.service";
            serviceConfig = {
              StateDirectory = mkForce serviceName;
              StateDirectoryMode = mkForce "0750";
              UMask = mkForce "0027";
              RestartSec = mkForce "5s";
              SupplementaryGroups = mkForce (lib.unique cfg.extraGroups);
            }
            // mkIf needsRuntimeEnv {
              EnvironmentFile = [ runtimeEnvPath ];
            }
            // mkIf (loadCredentialEntries != [ ]) {
              LoadCredential = loadCredentialEntries;
            };
          }
          (mkIf needsSecretFile {
            preStart = lib.mkAfter ''
              set -euo pipefail
              install -d -m 750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
              tmpFile="$(mktemp)"
              trap 'rm -f "$tmpFile"' EXIT
              ${optionalString (cfg.mqtt.passwordFile != null) ''
                printf "mqtt_password: %s\n" "$(cat "$CREDENTIALS_DIRECTORY/mqtt_password")" >> "$tmpFile"
              ''}
              ${optionalString (cfg.frontend.authTokenFile != null) ''
                printf "frontend_token: %s\n" "$(cat "$CREDENTIALS_DIRECTORY/frontend_token")" >> "$tmpFile"
              ''}
              ${optionalString (cfg.advanced.networkKeyFile != null) ''
                printf "network_key: %s\n" "$(cat "$CREDENTIALS_DIRECTORY/network_key")" >> "$tmpFile"
              ''}
              ${optionalString (cfg.advanced.panIdFile != null) ''
                printf "pan_id: %s\n" "$(cat "$CREDENTIALS_DIRECTORY/pan_id")" >> "$tmpFile"
              ''}
              ${optionalString (cfg.advanced.extPanIdFile != null) ''
                printf "ext_pan_id: %s\n" "$(cat "$CREDENTIALS_DIRECTORY/ext_pan_id")" >> "$tmpFile"
              ''}
              install -m 600 "$tmpFile" ${secretFilePath}
              chown ${cfg.user}:${cfg.group} ${secretFilePath}
              ${optionalString needsRuntimeEnv ''
                envFile="${runtimeEnvPath}"
                : > "$envFile"
                chmod 600 "$envFile"
                ${optionalString (cfg.advanced.panIdFile != null) ''
                  panValue="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/pan_id")"
                  printf 'ZIGBEE2MQTT_CONFIG_ADVANCED_PAN_ID=%s\n' "$panValue" >> "$envFile"
                ''}
                ${optionalString (cfg.advanced.extPanIdFile != null) ''
                  extPanValue="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/ext_pan_id")"
                  printf 'ZIGBEE2MQTT_CONFIG_ADVANCED_EXT_PAN_ID=%s\n' "$extPanValue" >> "$envFile"
                ''}
              ''}
            '';
          })
          (mkIf (devicesFilePath != null || groupsFilePath != null) {
            preStart = lib.mkAfter ''
              ensure_state_file() {
                target="$1"
                install -d -m 750 -o ${cfg.user} -g ${cfg.group} "$(dirname "$target")"
                if [ ! -e "$target" ]; then
                  install -m 640 -o ${cfg.user} -g ${cfg.group} /dev/null "$target"
                else
                  chown ${cfg.user}:${cfg.group} "$target"
                  chmod 640 "$target"
                fi
              }
              ${optionalString (devicesFilePath != null) ''ensure_state_file ${lib.escapeShellArg devicesFilePath}
              ''}${optionalString (groupsFilePath != null) ''ensure_state_file ${lib.escapeShellArg groupsFilePath}
              ''}
            '';
          })
          (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
            unitConfig.OnFailure = [ "notify@${serviceName}-failure:%n.service" ];
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
