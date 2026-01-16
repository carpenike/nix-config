# hosts/forge/services/scrypted.nix
#
# Host-specific configuration for Scrypted on 'forge'.
# Scrypted is a camera NVR platform with HomeKit/Google Home integration.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "scrypted.${domain}";
  dataDir = "/var/lib/scrypted";
  mediaMount =
    let
      mountCfg = config.modules.storage.nfsMounts.media or null;
    in
    if mountCfg != null && mountCfg ? localPath then mountCfg.localPath else "/mnt/data";
  nvrPath = "${mediaMount}/scrypted";
  dataset = "tank/services/scrypted";
  serviceEnabled = config.modules.services.scrypted.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.scrypted = {
        enable = true;
        hostname = serviceDomain;
        dataDir = dataDir;

        devices = [
          "/dev/dri:/dev/dri" # Intel iGPU for decoding and TensorRT/OpenCL paths
          "/dev/bus/usb:/dev/bus/usb" # Coral USB passthrough for TFLite delegate
        ];

        extraOptions = [ "--shm-size=1024m" ];

        mdns = {
          enable = true;
          mode = "container"; # Run Avahi inside container - host mode has DBus permission issues
        };

        nvr = {
          enable = true;
          path = nvrPath;
          datasetName = "scrypted-nvr";
          mountMode = "rw";
          manageStorage = false; # recordings live on NAS share mounted at /mnt/data
          group = "media";
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          # No external auth: Scrypted manages its own user database and MFA.
        };

        backup = {
          enable = true;
          repository = "nas-primary";
          useSnapshots = true;
          zfsDataset = dataset;
          tags = [ "scrypted" "config" ];
          excludePatterns = [
            "${nvrPath}/**"
            "/tmp/**"
          ];
        };

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        # Resource limits - previous 1536M caused repeated OOM kills (95+ kills in Dec 2025)
        # Object detection plugins (TensorFlow/OpenCV) spike to 800MB+ per python subprocess
        # Combined with node.js runtime, 4GB was insufficient
        # Updated 2025-12-31: Increased from 2560M to 4096M (sustained high usage)
        # Updated 2026-01-09: Increased to 6GB - container hitting 83% (3.58GB/4.3GB) with OOM
        #                     events occurring on subprocesses (node killed at 11:53:14)
        resources = {
          memory = "6144M";
          memoryReservation = "3072M";
          cpus = "4.0";
        };

        # HomeKit firewall - open mDNS and HAP ports for Apple Home app access
        homekit = {
          openFirewall = true;
          hapPorts = [
            34428 # Front Door
            47163 # Driveway
            43205 # Patio
            44467 # Additional HAP accessory
            21064 # Additional HAP accessory
          ];
        };

        # MQTT integration with EMQX broker for Home Assistant
        # NOTE: This provisions the EMQX user/ACLs. You must ALSO configure the
        # MQTT plugin in Scrypted's web UI with the same broker/username/password.
        mqtt = {
          enable = true;
          server = "mqtt://127.0.0.1:1883";
          username = "scrypted";
          passwordFile = config.sops.secrets."scrypted/mqtt_password".path;
          topicPrefix = "scrypted";
          # registerEmqxIntegration = true; # default - auto-registers user + ACLs
          # Default topics: scrypted/# and homeassistant/# for HA discovery
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "scrypted";

      modules.alerting.rules."scrypted-service-down" =
        forgeDefaults.mkServiceDownAlert "scrypted" "Scrypted" "camera NVR platform";
    })
  ];
}
