# Copyparty authenticated web access to the shared NAS media tree.
{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.copyparty.enable or false;
  serviceDomain = "files.${config.networking.domain}";
  mediaPath = "${config.modules.storage.nfsMounts.media.localPath}/media";
in
{
  config = lib.mkMerge [
    {
      modules.services.copyparty = {
        enable = true;
        nfsMountDependency = "media";
        readOnlyVolumes.media = mediaPath;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          caddySecurity = forgeDefaults.caddySecurity.media;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.services.gatus.contributions.copyparty = {
        name = "Files";
        group = "Media";
        url = "http://127.0.0.1:3923/";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
      };

      modules.alerting.rules."copyparty-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "copyparty"
          "Copyparty"
          "authenticated media file browser";

      modules.services.homepage.contributions.copyparty = {
        group = "Media";
        name = "Files";
        icon = "copyparty";
        href = "https://${serviceDomain}";
        description = "Browse shared media files";
        siteMonitor = "http://127.0.0.1:3923/";
      };
    })
  ];
}
