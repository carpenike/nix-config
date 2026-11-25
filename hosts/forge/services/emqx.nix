# hosts/forge/services/emqx.nix
#
# MQTT on 'forge'. Since 2026-11-25 the broker is EMQX in the k8s cluster
# (carpenike/k8s-gitops ADR 0018, docs/apps/home-automation.md). Forge's own
# EMQX is disabled, and a TCP forwarder keeps :1883 here pointing at the
# cluster's LoadBalancer `emqx-forge` (10.45.10.30), which accepts only
# Forge's address. Every client that used Forge's broker keeps its settings:
# Home Assistant, Z-Wave JS UI and Scrypted's MQTT plugin store the broker in
# their own UI, zigbee2mqtt and Frigate dial 127.0.0.1, TeslaMate dials
# host.containers.internal, and the cluster Scrypted's forwarder dials
# 10.20.0.30. Their users and passwords are the same in the cluster broker
# (1Password item `emqx`, copied from this host's sops file).
#
# Rollback: set modules.services.emqx.enable back to true (the forwarder
# yields to it) and put "podman-emqx" back in containersByRestartSec."0" in
# core/systemd-restart-policy.nix. The dataset is untouched (nothing runs `zfs destroy`), but its
# snapshots and backups stop while the module is disabled; the broker's state
# is users and retained messages, which the clients recreate.
#
# Delete the forwarder when the last Forge client moves to the cluster.

{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceEnabled = config.modules.services.emqx.enable or false;
  dataset = "tank/services/emqx";
  dataDir = "/var/lib/emqx";
  dashboardDomain = "emqx.${domain}";
  # k8s-gitops kubernetes/apps/home-automation/emqx/app/service-forge.yaml
  clusterBroker = "10.45.10.30:1883";
in
{
  config = lib.mkMerge [
    {
      modules.services.emqx = {
        enable = false;
        dataDir = dataDir;
        datasetPath = dataset;
        allowAnonymous = false;

        # Open firewall for MQTT clients (IoT devices on LAN)
        openFirewall = true;
        timezone = config.time.timeZone or "UTC";
        dashboard = {
          enable = true;
          passwordFile = config.sops.secrets."emqx/dashboard_password".path;
          reverseProxy = {
            enable = true;
            hostName = dashboardDomain;
            backend = {
              host = "127.0.0.1";
              port = 18083;
            };
          };
        };
        backup = forgeDefaults.mkBackupWithTags "emqx" [ "emqx" "mqtt" ];

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "emqx";

      # Service availability alert (emqx is a native systemd service, not container)
      modules.alerting.rules."emqx-service-down" =
        # EMQX runs as a container, so the unit is podman-emqx.service and the
        # bare "emqx" matched no series. Uses the systemd helper rather than
        # the container one because the churn/down pair should follow the unit
        # that actually exists.
        forgeDefaults.mkSystemdServiceDownAlert "podman-emqx" "EMQX" "MQTT broker";
    })

    (lib.mkIf (!serviceEnabled) {
      systemd.services.mqtt-forward-cluster = {
        description = "Forward MQTT on :1883 to the cluster EMQX";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:1883,fork,reuseaddr,keepalive TCP:${clusterBroker},keepalive";
          Restart = "always";
          RestartSec = 5;
          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          MemoryMax = "128M";
        };
      };

      # Same exposure as the EMQX module's openFirewall: local containers
      # (TeslaMate via host.containers.internal) and the cluster Scrypted
      # reach :1883 here. Every client still authenticates at the broker.
      networking.firewall.allowedTCPPorts = [ 1883 ];

      modules.alerting.rules."mqtt-forward-cluster-down" =
        forgeDefaults.mkSystemdServiceDownAlert "mqtt-forward-cluster" "MQTTForwardCluster" "MQTT forwarder to the cluster broker";
    })
  ];
}
