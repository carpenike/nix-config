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

        image = "ghcr.io/esphome/esphome:2025.11.4@sha256:e72eac8e67470c46c9efea029110e451b37062d46b7e55269e03756dc15f7fbb";
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
