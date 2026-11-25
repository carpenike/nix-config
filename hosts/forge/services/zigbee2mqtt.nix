# hosts/forge/services/zigbee2mqtt.nix
#
# Zigbee2MQTT on 'forge'. Since 2026-11-25 it runs in the k8s cluster
# (carpenike/k8s-gitops ADR 0018, docs/apps/home-automation.md, "2.
# zigbee2mqtt"). Only one process may hold the network coordinator
# (10.30.100.183:6638), so the service is disabled here before the cluster
# pod starts. The settings below stay as the record of what Forge ran and for
# rollback; the cluster runs on a copy of /var/lib/zigbee2mqtt.
#
# The dataset is kept as the rollback copy, still snapshotted, replicated and
# backed up under the same names (the block at the end, gated on the service
# being off), as hosts/forge/services/retired-to-cluster.nix does for the
# November moves. Only the `automated-restore` tier is dropped: it is the
# preseed unit, which has no service left to precede.
#
# Rollback: scale the cluster's zigbee2mqtt to 0 first, then set
# modules.services.zigbee2mqtt.enable back to true and put "zigbee2mqtt" back
# in containersByRestartSec."0" in core/systemd-restart-policy.nix and in
# failClosedUnits in flake.nix. After days in the cluster, copy the volume
# back before starting it here, or Forge forgets what was paired since.
#
# Delete the retention block after the rollback week.

{ config, lib, pkgs, ... }:
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
        enable = false;
        package = pkgs.unstable.zigbee2mqtt;
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
      modules.storage.datasets.services.zigbee2mqtt.protection = {
        class = "critical";
        objectives = {
          onsiteRpoSeconds = 900;
          offsiteRpoSeconds = 86400;
          rtoSeconds = 7200;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "offsite-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "zigbee2mqtt-state";
        allowEmptyBootstrap = false;
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zigbee2mqtt";

      modules.alerting.rules."zigbee2mqtt-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "zigbee2mqtt" "Zigbee2MQTT" "Zigbee device bridge";
    })

    # Retention while the service runs in the cluster: the same dataset,
    # sanoid/syncoid and Restic job (`service-zigbee2mqtt`, the name backup
    # discovery gave it) as when it ran here.
    (lib.mkIf (!serviceEnabled) {
      # The upstream module created this user with nixpkgs' fixed ids.
      users.users.zigbee2mqtt = {
        uid = config.ids.uids.zigbee2mqtt;
        group = "zigbee2mqtt";
        isSystemUser = true;
        description = "Zigbee2MQTT user (moved to k8s; data owner)";
        home = "/var/empty";
      };
      users.groups.zigbee2mqtt.gid = config.ids.gids.zigbee2mqtt;

      modules.storage.datasets.services.zigbee2mqtt = {
        mountpoint = dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "zigbee2mqtt";
        group = "zigbee2mqtt";
        mode = "0750";
        protection = {
          class = "critical";
          objectives = {
            onsiteRpoSeconds = 900;
            offsiteRpoSeconds = 86400;
            rtoSeconds = 7200;
          };
          requiredTiers = [
            "local-snapshot"
            "replication"
            "nas-backup"
            "offsite-backup"
          ];
          consistency = "crash-consistent";
          validator = "zigbee2mqtt-state";
          allowEmptyBootstrap = true;
          notes = ''
            Moved to the k8s cluster 2026-11-25. This dataset is the rollback
            copy as of the cutover; delete it in a follow-up after a week.
          '';
        };
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zigbee2mqtt";

      modules.services.backup.restic.jobs.service-zigbee2mqtt = {
        enable = true;
        inherit (forgeDefaults.backup) repository;
        paths = [ dataDir ];
        tags = [ "zigbee2mqtt" "zigbee" "automation" "forge" ];
        excludePatterns = [ "**/log/**" "**/tmp/**" ]
          ++ config.modules.services.backup.serviceDiscovery.globalExcludes;
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };
    })
  ];
}
