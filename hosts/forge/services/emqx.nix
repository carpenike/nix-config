{ config, lib, ... }:
let
  inherit (config.networking) domain;
  serviceEnabled = config.modules.services.emqx.enable;
  dataset = "tank/services/emqx";
  dataDir = "/var/lib/emqx";
  dashboardDomain = "emqx.${domain}";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/emqx";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
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
      };
    }

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = replicationTargetHost;
          targetDataset = replicationTargetDataset;
          hostKey = replicationHostKey;
          sendOptions = "wp";
          recvOptions = "u";
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })
  ];
}
