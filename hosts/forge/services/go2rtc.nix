# hosts/forge/services/go2rtc.nix
#
# go2rtc streaming relay for camera rebroadcasting.
# Converts Scrypted RTSP streams to WebRTC for Home Assistant.
#
# Architecture: Scrypted (camera source) → RTSP → go2rtc → WebRTC → Home Assistant
#
# Stream configuration:
#   Streams are defined in cfg.streams as name → RTSP URL mappings.
#   Get Scrypted RTSP URLs from: Scrypted UI → Camera → Rebroadcast Plugin → RTSP URL

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "go2rtc.${domain}";
  dataset = "tank/services/go2rtc";
  serviceEnabled = config.modules.services.go2rtc.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.go2rtc = {
        enable = true;
        hostname = serviceDomain;

        # Default ports (go2rtc standard)
        apiPort = 1984;
        rtspPort = 8554;
        webrtcPort = 8555;

        # Open firewall for RTSP/WebRTC streaming (Home Assistant access)
        openFirewall = true;

        # Camera streams from Scrypted Rebroadcast Plugin
        # Scrypted runs on host network, so localhost works
        streams = {
          front_door = "rtsp://127.0.0.1:39802/8aeb874bb81c6e55"; # Amcrest Doorbell
          driveway = "rtsp://127.0.0.1:39801/b66f9286d035dfa4"; # Hikvision
          patio = "rtsp://127.0.0.1:39803/64e0e7d2df00d281"; # Hikvision
        };

        # Reverse proxy with admin authentication
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };

        # Notifications on failure
        notifications.enable = true;

        # go2rtc has minimal persistent state - backup not critical
        # but enable for config consistency
        backup = forgeDefaults.backup;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS replication for DR
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "go2rtc";

      # Service health monitoring
      modules.alerting.rules."go2rtc-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "go2rtc" "go2rtc" "camera streaming relay";

      # Gatus endpoint for user-facing availability
      modules.services.gatus.contributions.go2rtc = {
        name = "go2rtc";
        group = "Home Automation";
        url = "http://127.0.0.1:1984/api";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
        ];
      };
    })
  ];
}
