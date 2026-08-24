# hosts/forge/services/esphome.nix
#
# Host-specific configuration for ESPHome on 'forge'.
# ESPHome provides firmware development for ESP8266/ESP32 IoT devices.

{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  domain = config.networking.domain;
  serviceDomain = "esphome.${domain}";
  dataset = "tank/services/esphome";
  serviceEnabled = config.modules.services.esphome.enable or false;
  fleetMetricsFile = "/var/lib/node_exporter/textfile_collector/esphome_fleet.prom";
  fleetStatusFile = "/var/lib/node_exporter/textfile_collector/esphome_fleet_collector.prom";
  fleetMetricsPackage = pkgs.runCommand "esphome-fleet-metrics"
    {
      nativeBuildInputs = [ pkgs.python3 ];
    } ''
    mkdir -p source/esphome
    touch source/esphome/__init__.py
    cp ${./esphome/fleet_metrics.py} source/esphome/fleet_metrics.py
    cp ${./esphome/test_fleet_metrics.py} source/esphome/test_fleet_metrics.py
    cd source
    python3 -m unittest -v esphome.test_fleet_metrics
    install -Dm755 esphome/fleet_metrics.py "$out/bin/esphome-fleet-metrics"
    patchShebangs "$out/bin/esphome-fleet-metrics"
  '';

  lanCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
in
{
  config = lib.mkMerge [
    {
      modules.services.esphome = {
        enable = true;

        # Uses default home-operations image from module
        hostNetwork = true; # needed for ICMP dashboard checks + mDNS discovery
        dataDir = "/var/lib/esphome";
        secretsFile = config.sops.secrets."esphome/secrets.yaml".path;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          caddySecurity = {
            enable = true;
            portal = "pocketid";
            policy = "lan-only";
            allowedNetworks = lanCidrs;
            claimRoles = [
              {
                claim = "groups";
                value = "automation";
                role = "automation";
              }
            ];
          };
          security.customHeaders = {
            "Referrer-Policy" = "strict-origin-when-cross-origin";
            "X-Frame-Options" = "SAMEORIGIN";
          };
        };

        backup = forgeDefaults.mkBackupWithTags "esphome" [ "esphome" "config" "firmware" "forge" ];

        notifications = {
          enable = true;
          channels.onFailure = [ "automation-alerts" ];
        };

        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.esphome.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = null;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "esphome-config";
        allowEmptyBootstrap = false;
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "esphome";

      modules.services.gatus.contributions = {
        garage-upright-freezer-esphome = {
          name = "Garage Upright Freezer ESPHome API";
          group = "Home Automation";
          url = "tcp://garage-upright-freezer.${domain}:6053";
          interval = "30s";
          conditions = [
            "[CONNECTED] == true"
            "[RESPONSE_TIME] < 1000"
          ];
          alerts = [{
            description = "The garage upright freezer ESPHome API is unreachable or taking over one second to accept connections.";
          }];
        };

        garage-chest-freezer-esphome = {
          name = "Garage Chest Freezer ESPHome API";
          group = "Home Automation";
          url = "tcp://garage-chest-freezer.${domain}:6053";
          interval = "30s";
          conditions = [
            "[CONNECTED] == true"
            "[RESPONSE_TIME] < 1000"
          ];
          alerts = [{
            description = "The garage chest freezer ESPHome API is unreachable or taking over one second to accept connections.";
          }];
        };
      };

      systemd.services.esphome-fleet-metrics = {
        description = "Export ESPHome fleet health metrics for Prometheus";
        after = [ "network-online.target" "podman-esphome.service" ];
        wants = [ "network-online.target" "podman-esphome.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "node-exporter";
          Group = "node-exporter";
          ExecStart = lib.concatStringsSep " " [
            "${fleetMetricsPackage}/bin/esphome-fleet-metrics"
            "--domain ${lib.escapeShellArg domain}"
            "--policy-file ${./esphome/fleet_policy.json}"
            "--metrics-file ${fleetMetricsFile}"
            "--status-file ${fleetStatusFile}"
            "--resolver-command ${pkgs.getent}/bin/getent"
            "--resolver-timeout 2"
          ];
          TimeoutStartSec = "45s";
          UMask = "0022";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
        };
      };

      systemd.timers.esphome-fleet-metrics = {
        description = "Collect ESPHome fleet health metrics every minute";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "1m";
          AccuracySec = "5s";
          RandomizedDelaySec = "5s";
          Persistent = true;
          Unit = "esphome-fleet-metrics.service";
        };
      };

      modules.alerting.rules."esphome-fleet-collector-error" = {
        type = "promql";
        alertname = "ESPHomeFleetCollectorError";
        expr = "esphome_fleet_collector_success == 0";
        for = "2m";
        severity = "high";
        labels = { service = "esphome"; category = "monitoring"; };
        annotations = {
          summary = "ESPHome fleet collection is failing on {{ $labels.instance }}";
          description = "The collector cannot refresh ESPHome fleet health. Check: journalctl -u esphome-fleet-metrics.service";
        };
      };

      modules.alerting.rules."esphome-fleet-collector-stale" = {
        type = "promql";
        alertname = "ESPHomeFleetCollectorStale";
        expr = ''
          (time() - esphome_fleet_last_attempt_timestamp_seconds > 240)
          or absent(esphome_fleet_last_attempt_timestamp_seconds)
        '';
        for = "2m";
        severity = "high";
        labels = { service = "esphome"; category = "monitoring"; };
        annotations = {
          summary = "ESPHome fleet collector is stale on {{ $labels.instance }}";
          description = "The collector has not attempted a run for over four minutes. Check: systemctl status esphome-fleet-metrics.timer";
        };
      };

      modules.alerting.rules."esphome-service-down" =
        forgeDefaults.mkServiceDownAlert "esphome" "ESPHome" "IoT firmware development";
    })
  ];
}
