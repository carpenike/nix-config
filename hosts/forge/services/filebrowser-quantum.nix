# FileBrowser Quantum authenticated media browser.
{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.filebrowserQuantum.enable or false;
  serviceDomain = "files.${config.networking.domain}";
  mediaPath = "${config.modules.storage.nfsMounts.media.localPath}/media";
in
{
  config = lib.mkMerge [
    {
      modules.services.filebrowserQuantum = {
        enable = true;
        sourcePath = mediaPath;
        sourceName = "Media";
        nfsMountDependency = "media";

        oidc = {
          enable = true;
          adminGroup = "quantum-admins";
          clientId = "quantum";
          clientSecretFile = config.sops.secrets."filebrowser-quantum/oidc-client-secret".path;
          issuerUrl = "https://id.${config.networking.domain}";
          userGroups = [ "media" ];
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
        };
      };

      modules.services.caddy.virtualHosts.${serviceDomain}.cloudflare = {
        enable = true;
        tunnel = "forge";
        dns = {
          recordType = "CNAME";
          target = "forge.${config.networking.domain}";
          proxied = false;
          ttl = 3600;
          comment = "FileBrowser Quantum media browser";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.services.gatus.contributions.filebrowser-quantum = {
        name = "Files";
        group = "Media";
        url = "http://127.0.0.1:3924/health";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
      };

      modules.alerting.rules."filebrowser-quantum-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "filebrowser-quantum"
          "FileBrowser Quantum"
          "modern authenticated media file browser";

      modules.services.homepage.contributions.filebrowser-quantum = {
        group = "Media";
        name = "Files";
        icon = "mdi-folder-multiple-image";
        href = "https://${serviceDomain}";
        description = "Browse shared media files";
        siteMonitor = "http://127.0.0.1:3924/health";
      };
    })
  ];
}
