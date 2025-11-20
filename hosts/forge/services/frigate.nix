{ config, lib, ... }:
let
  inherit (config.networking) domain;
  serviceDomain = "frigate.${domain}";
  authDomain = "auth.${domain}";
  dataset = "tank/services/frigate";
  dataDir = "/var/lib/frigate";
  cacheDir = "/var/cache/frigate";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/frigate";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
  frigateMqttPasswordFile = lib.attrByPath [ "sops" "secrets" "frigate/mqtt_password" "path" ] null config;
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
          authelia = {
            enable = true;
            instance = "main";
            authDomain = authDomain;
            policy = "two_factor";
            allowedGroups = [ "admins" "security" ];
            bypassPaths = [
              "/api/stats"
              "/api/version"
            ];
            allowedNetworks = [
              "172.16.0.0/12"
              "192.168.1.0/24"
              "10.0.0.0/8"
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

        backup = {
          enable = true;
          repository = "nas-primary";
          tags = [ "frigate" "nvr" ];
        };

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

    {
      modules.backup.sanoid.datasets.${dataset} = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = replicationTargetHost;
          targetDataset = replicationTargetDataset;
          hostKey = replicationHostKey;
          sendOptions = "wp";
          recvOptions = "u";
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    }

    {
      modules.alerting.rules."frigate-service-down" = {
        type = "promql";
        alertname = "FrigateServiceDown";
        expr = ''node_systemd_unit_state{name="frigate.service",state="active"} == 0'';
        for = "2m";
        severity = "critical";
        labels = {
          service = "frigate";
          category = "nvr";
        };
        annotations = {
          summary = "Frigate service is down on {{ $labels.instance }}";
          description = "Security camera processing stopped. Inspect systemctl status frigate.service.";
        };
      };

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
    }
  ];
}
