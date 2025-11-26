{ config, lib, ... }:

let
  inherit (lib) optionalAttrs;

  domain = config.networking.domain;
  serviceDomain = "esphome.${domain}";
  dataset = "tank/services/esphome";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/esphome";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
  serviceEnabled = config.modules.services.esphome.enable or false;
  resticEnabled = (config.modules.backup.enable or false) && (config.modules.backup.restic.enable or false);

  lanCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
in {
  config = lib.mkMerge [
    {
      modules.services.esphome = {
        enable = true;

        image = "ghcr.io/esphome/esphome:2025.11.1@sha256:02ca34d33789b1c7f4389c644d28e7f6892c26f931a67972e74221a8932d1457";
        hostNetwork = true;  # needed for ICMP dashboard checks + mDNS discovery
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

        backup = {
          enable = true;
          repository = "nas-primary";
          useSnapshots = true;
          zfsDataset = dataset;
          tags = [ "esphome" "config" "firmware" ];
        };

        notifications = {
          enable = true;
          channels.onFailure = [ "automation-alerts" ];
        };

        preseed = {
          enable = resticEnabled;
        } // optionalAttrs resticEnabled {
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
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

      modules.alerting.rules."esphome-service-down" = {
        type = "promql";
        alertname = "ESPHomeDashboardDown";
        expr = ''container_service_active{name="esphome"} == 0'';
        for = "2m";
        severity = "high";
        labels = {
          service = "esphome";
          category = "automation";
        };
        annotations = {
          summary = "ESPHome dashboard is unavailable on {{ $labels.instance }}";
          description = ''Check systemctl status podman-esphome.service and container logs.'';
          command = "systemctl status podman-esphome.service";
        };
      };
    })
  ];
}
