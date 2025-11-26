{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.cooklangFederation.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.cooklangFederation = {
        enable = true;
    dataDir = "/data/cooklang-federation";
    datasetPath = "tank/services/cooklang-federation";
    listenAddress = "127.0.0.1";
    port = 9086;
    externalUrl = "https://fedcook.holthome.net";
    feedConfigFile = ../../files/cooklang-federation/feeds.yaml;

    reverseProxy = {
      enable = true;
      hostName = "fedcook.holthome.net";
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = 9086;
      };
    };

    healthcheck = {
      enable = true;
      metrics.enable = true;
      interval = "5m";
      timeout = "10s";
      path = "/health";
    };

    backup = {
      enable = true;
      repository = "nas-primary";
      tags = [ "cooklang" "federation" "recipes" ];
    };

    preseed = forgeDefaults.mkPreseed [ "syncoid" "restic" ];

        notifications.enable = true;

        github = {
          enable = true;
          tokenFile = config.sops.secrets."github/cooklang-token".path;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services."cooklang-federation" = {
        mountpoint = "/data/cooklang-federation";
        recordsize = "16K";
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        owner = config.modules.services.cooklangFederation.user;
        group = config.modules.services.cooklangFederation.group;
        mode = "0750";
      };

      modules.backup.sanoid.datasets."tank/services/cooklang-federation" = forgeDefaults.mkSanoidDataset "cooklang-federation";

      modules.alerting.rules."cooklang-federation-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "cooklang-federation" "CooklangFederation" "recipe feed aggregation";

      modules.services.caddy.virtualHosts.cooklangFederation.cloudflare = {
        enable = true;
        tunnel = "forge";
      };
    })
  ];
}
