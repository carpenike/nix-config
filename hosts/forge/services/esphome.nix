# hosts/forge/services/esphome.nix
#
# Host-specific configuration for ESPHome on 'forge'.
# ESPHome provides firmware development for ESP8266/ESP32 IoT devices.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  domain = config.networking.domain;
  serviceDomain = "esphome.${domain}";
  dataset = "tank/services/esphome";
  serviceEnabled = config.modules.services.esphome.enable or false;

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

        image = "ghcr.io/esphome/esphome:2025.12.3@sha256:1edb11006e70dac129f58e2a641a90478bf34662f1bd84243a92b87a0b46cd26";
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
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "esphome";

      modules.alerting.rules."esphome-service-down" =
        forgeDefaults.mkServiceDownAlert "esphome" "ESPHome" "IoT firmware development";
    })
  ];
}
