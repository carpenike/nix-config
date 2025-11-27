# hosts/forge/services/frigate.nix
#
# Host-specific configuration for Frigate NVR on 'forge'.
# Frigate is a real-time AI-powered security camera system.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "frigate.${domain}";
  dataset = "tank/services/frigate";
  dataDir = "/var/lib/frigate";
  cacheDir = "/var/cache/frigate";
  frigateMqttPasswordFile = lib.attrByPath [ "sops" "secrets" "frigate/mqtt_password" "path" ] null config;
  serviceEnabled = config.modules.services.frigate.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.frigate = {
        enable = false;
        hostname = serviceDomain;
        dataDir = dataDir;
        mediaDir = dataDir;
        cacheDir = cacheDir;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
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
              {
                claim = "groups";
                value = "security";
                role = "admins";
              }
            ];
          };
        };

        detectors = {
          coral = {
            type = "edgetpu";
            device = "usb";
          };
        };

        recordingPolicy = {
          retainDays = 7;
          eventRetainDays = 30;
          snapshotRetainDays = 14;
          mode = "all";
        };

        mqtt = {
          enable = true;
          host = "127.0.0.1";
          username = "frigate";
          passwordFile = frigateMqttPasswordFile;
          topicPrefix = "frigate";
          clientId = "${config.networking.hostName}-frigate";
          allowedTopics = [
            "frigate/#"
            "homeassistant/frigate/#"
          ];
        };

        go2rtc = {
          enable = true;
          settings = {
            api.listen = ":1984";
          };
        };

        backup = forgeDefaults.mkBackupWithTags "frigate" [ "frigate" "nvr" "security" ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        settings = {
          birdseye = {
            enabled = true;
            restream = true;
            mode = "continuous";
          };
          ui.timezone = config.time.timeZone;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "frigate";

      # Service availability alerts
      modules.alerting.rules."frigate-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "frigate" "Frigate" "NVR security camera";

      modules.alerting.rules."go2rtc-service-down" = {
        type = "promql";
        alertname = "Go2RTCServiceDown";
        expr = ''node_systemd_unit_state{name="go2rtc.service",state="active"} == 0'';
        for = "2m";
        severity = "medium";
        labels = {
          service = "frigate";
          component = "go2rtc";
        };
        annotations = {
          summary = "go2rtc restreaming bridge is down on {{ $labels.instance }}";
          description = "Review systemctl status go2rtc.service and associated logs.";
        };
      };
    })
  ];
}
