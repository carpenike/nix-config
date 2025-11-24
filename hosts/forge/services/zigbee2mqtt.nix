{ config, lib, ... }:
let
  inherit (config.networking) domain;
  dataset = "tank/services/zigbee2mqtt";
  dataDir = "/var/lib/zigbee2mqtt";
  controllerAddress = "tcp://10.30.100.183:6638";
  frontendDomain = "zigbee.${domain}";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/zigbee2mqtt";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
  serviceEnabled = config.modules.services.zigbee2mqtt.enable;
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

        backup = {
          enable = true;
          repository = "nas-primary";
          zfsDataset = dataset;
          tags = [ "zigbee" "automation" "forge" ];
        };

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
      modules.backup.sanoid.datasets.${dataset} = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = replicationTargetHost;
          targetDataset = replicationTargetDataset;
          sendOptions = "wp";
          recvOptions = "u";
          hostKey = replicationHostKey;
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })

    (lib.mkIf serviceEnabled {
      modules.alerting.rules."zigbee2mqtt-service-down" = {
        type = "promql";
        alertname = "Zigbee2MQTTServiceDown";
        expr = ''systemd_unit_state{name="zigbee2mqtt.service",state="active"} == 0'';
        for = "2m";
        severity = "high";
        labels = {
          service = "zigbee2mqtt";
          category = "automation";
        };
        annotations = {
          summary = "Zigbee2MQTT is down";
          description = ''The zigbee2mqtt service on {{ $labels.instance }} has been inactive for 2 minutes. Automations relying on Zigbee devices are impacted.'';
          command = "journalctl -u zigbee2mqtt -n 200";
        };
      };
    })
  ];
}
