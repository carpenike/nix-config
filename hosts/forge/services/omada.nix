# hosts/forge/services/omada.nix
#
# Host-specific configuration for the TP-Link Omada SDN Controller on forge.
# Initial data cutover: docs/services/omada-luna-to-forge.md

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.omada.enable or false;
  serviceDomain = "omada.${config.networking.domain}";
  dataset = "tank/services/omada";
in
{
  config = lib.mkMerge [
    {
      modules.services.omada = {
        enable = true;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            scheme = "https";
            host = "127.0.0.1";
            port = 8043;
          };
        };

        backup = forgeDefaults.mkBackupWithTags "omada" [
          "network"
          "omada"
          "config"
          "forge"
        ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        resources = {
          memory = "4g";
          memoryReservation = "2g";
          cpus = "2.0";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.omada = {
        mountpoint = "/var/lib/omada";
        recordsize = "16K";
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        owner = config.modules.services.omada.user;
        group = config.modules.services.omada.group;
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
            "automated-restore"
          ];
          consistency = "crash-consistent";
          validator = "omada-mongodb";
          allowEmptyBootstrap = false;
        };
      };

      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "omada";

      modules.alerting.rules."omada-service-down" =
        forgeDefaults.mkServiceDownAlert "omada" "Omada" "SDN controller";

      modules.services.homepage.contributions.omada = {
        group = "Infrastructure";
        name = "Omada";
        icon = "omada";
        href = "https://${serviceDomain}";
        description = "SDN Controller";
        widget = {
          type = "omada";
          url = "https://${serviceDomain}";
          username = "{{HOMEPAGE_VAR_OMADA_USERNAME}}";
          password = "{{HOMEPAGE_VAR_OMADA_PASSWORD}}";
          site = "SLC";
        };
      };

      modules.services.gatus.contributions.omada = {
        name = "Omada";
        group = "Infrastructure";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
      };
    })
  ];
}
