# hosts/forge/services/zigbee2mqtt.nix
#
# Host-specific configuration for Zigbee2MQTT on 'forge'.
# Zigbee2MQTT bridges Zigbee devices to MQTT for Home Assistant integration.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  dataset = "tank/services/zigbee2mqtt";
  dataDir = "/var/lib/zigbee2mqtt";
  controllerAddress = "tcp://10.30.100.183:6638";
  frontendDomain = "zigbee.${domain}";
  serviceEnabled = config.modules.services.zigbee2mqtt.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.zigbee2mqtt = {
        enable = true;
        dataDir = dataDir;

        reverseProxy = {
          enable = true;
          hostName = frontendDomain;
          caddySecurity = {
            enable = true;
            portal = "pocketid";
            policy = "admins";
            claimRoles = [
              {
                claim = "groups";
                value = "admins";
                role = "admins";
              }
            ];
          };
        };

        frontend = {
          port = 8282;
        };

        serial = {
          port = controllerAddress;
          adapter = "zstack";
          baudrate = 115200;
          advanced = {
            transmitPower = 20;
            disableLed = false;
          };
        };

        permitJoin = false;

        mqtt = {
          server = "mqtt://127.0.0.1:1883";
          baseTopic = "zigbee2mqtt";
          username = "zigbee2mqtt";
          passwordFile = config.sops.secrets."zigbee2mqtt/mqtt_password".path;
          keepalive = 60;
          protocolVersion = 5;
          includeDeviceInformation = true;
        };

        backup = forgeDefaults.mkBackupWithTags "zigbee2mqtt" [ "zigbee" "automation" "forge" ];

        devicesFile = "devices.yaml";
        groupsFile = "groups.yaml";

        notifications = {
          enable = true;
          channels.onFailure = [ "critical-alerts" ];
          customMessages.failure = ''
Zigbee2MQTT failed on ${config.networking.hostName}.
Use `journalctl -u zigbee2mqtt -n 200` for details.
'';
        };

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        advanced = {
          logLevel = "info";
          networkKeyFile = config.sops.secrets."zigbee2mqtt/network_key".path;
          panIdFile = config.sops.secrets."zigbee2mqtt/pan_id".path;
          extPanIdFile = config.sops.secrets."zigbee2mqtt/ext_pan_id".path;
          channel = 25;
          homeassistantLegacyEntityAttributes = false;
          homeassistantLegacyTriggers = false;
          homeassistantStatusTopic = "homeassistant/status";
          lastSeen = "ISO_8601";
          legacyAvailabilityPayload = false;
          logOutput = [ "console" ];
        };

        extraSettings = {
          availability = {
            active = { timeout = 60; };
            passive = { timeout = 2000; };
          };
          device_options = {
            legacy = false;
            retain = true;
          };
          experimental = {
            new_api = true;
          };
          frontend = {
            url = "https://${frontendDomain}";
          };
          homeassistant = {
            discovery_topic = "homeassistant";
            legacy_entity_attributes = false;
          };
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zigbee2mqtt";

      modules.alerting.rules."zigbee2mqtt-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "zigbee2mqtt" "Zigbee2MQTT" "Zigbee device bridge";
    })
  ];
}
