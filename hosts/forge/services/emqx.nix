# hosts/forge/services/emqx.nix
#
# Host-specific configuration for the EMQX MQTT broker on 'forge'.
# EMQX provides MQTT messaging for IoT and home automation services.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceEnabled = config.modules.services.emqx.enable or false;
  dataset = "tank/services/emqx";
  dataDir = "/var/lib/emqx";
  dashboardDomain = "emqx.${domain}";
in
{
  config = lib.mkMerge [
    {
      modules.services.emqx = {
        enable = true;
        dataDir = dataDir;
        datasetPath = dataset;
        allowAnonymous = false;
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
        backup = {
          enable = true;
          repository = "nas-primary";
          zfsDataset = dataset;
          frequency = "daily";
          tags = [ "emqx" "mqtt" ];
        };

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "emqx";

      # Service availability alert (emqx is a native systemd service, not container)
      modules.alerting.rules."emqx-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "emqx" "EMQX" "MQTT broker";
    })
  ];
}
