{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  dataset = "tank/services/zwave-js-ui";
  dataDir = "/var/lib/zwave-js-ui";
  controllerAddress = "/dev/serial/by-id/usb-0658_0200-if00";
  frontendDomain = "zwave.${domain}";
  serviceEnabled = config.modules.services."zwave-js-ui".enable;
  unstablePkgs = pkgs.unstable;
in
{
  config = lib.mkMerge [
    {
      modules.services."zwave-js-ui" = {
        enable = true;
        dataDir = dataDir;
        package = unstablePkgs.zwave-js-ui;

        reverseProxy = {
          enable = true;
          hostName = frontendDomain;
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
            ];
          };
        };

        ui = {
          listenAddress = "127.0.0.1";
          port = 8091;
        };

        serial.device = controllerAddress;

        zwave.serverPort = 3002;

        mqtt = {
          enable = true;
          baseTopic = "zwave";
          username = "zwave-js-ui";
          passwordFile = config.sops.secrets."zwave-js-ui/mqtt_password".path;
        };

        security = {
          sessionSecretFile = config.sops.secrets."zwave-js-ui/session_secret".path;
          s0LegacyKeyFile = config.sops.secrets."zwave-js-ui/s0_legacy_key".path;
          s2UnauthenticatedKeyFile = config.sops.secrets."zwave-js-ui/s2_unauthenticated_key".path;
          s2AuthenticatedKeyFile = config.sops.secrets."zwave-js-ui/s2_authenticated_key".path;
          s2AccessControlKeyFile = config.sops.secrets."zwave-js-ui/s2_access_control_key".path;
          s2LongRangeKeyFile = config.sops.secrets."zwave-js-ui/s2_long_range_key".path;
          s2LongRangeAccessControlKeyFile = config.sops.secrets."zwave-js-ui/s2_long_range_access_control_key".path;
        };

        backup = {
          enable = true;
          repository = "nas-primary";
          zfsDataset = dataset;
          tags = [ "zwave" "automation" "forge" ];
          excludePatterns = [ "**/log/**" "**/tmp/**" ];
        };

        notifications = {
          enable = true;
          channels.onFailure = [ "critical-alerts" ];
          customMessages.failure = ''
Z-Wave JS UI failed on ${config.networking.hostName}.
Use `journalctl -u zwave-js-ui -n 200` for details.
'';
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zwave-js-ui";

      modules.alerting.rules."zwave-js-ui-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "zwave-js-ui" "ZwaveJsUi" "Z-Wave device bridge";
    })
  ];
}
