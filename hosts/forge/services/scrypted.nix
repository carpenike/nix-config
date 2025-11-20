{ config, lib, ... }:
let
  inherit (config.networking) domain;
  serviceDomain = "scrypted.${domain}";
  authDomain = "auth.${domain}";
  dataDir = "/var/lib/scrypted";
  mediaMount =
    let
      mountCfg = config.modules.storage.nfsMounts.media or null;
    in
    if mountCfg != null && mountCfg ? localPath then mountCfg.localPath else "/mnt/data";
  nvrPath = "${mediaMount}/scrypted";
  dataset = "tank/services/scrypted";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/scrypted";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
in
{
  config = lib.mkMerge [
    {
      modules.services.scrypted = {
        enable = true;
        hostname = serviceDomain;
        dataDir = dataDir;

        devices = [
          "/dev/dri:/dev/dri"            # Intel iGPU for decoding and TensorRT/OpenCL paths
          "/dev/bus/usb:/dev/bus/usb"    # Coral USB passthrough for TFLite delegate
        ];

        extraOptions = [ "--shm-size=1024m" ];

        mdns = {
          enable = true;
          mode = "container";  # Run Avahi inside the container to avoid host-level socket mapping complexity
        };

        nvr = {
          enable = true;
          path = nvrPath;
          datasetName = "scrypted-nvr";
          mountMode = "rw";
          manageStorage = false; # recordings live on NAS share mounted at /mnt/data
          group = "media";
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          authelia = {
            enable = true;
            instance = "main";
            authDomain = authDomain;
            policy = "two_factor";
            allowedGroups = [ "admins" "security" ];
            allowedNetworks = [
              "172.16.0.0/12"
              "192.168.1.0/24"
              "10.0.0.0/8"
            ];
            bypassPaths = [ "/api/health" ];
          };
        };

        backup = {
          enable = true;
          repository = "nas-primary";
          useSnapshots = true;
          zfsDataset = dataset;
          tags = [ "scrypted" "config" ];
          excludePatterns = [
            "${nvrPath}/**"
            "/tmp/**"
          ];
        };

        notifications.enable = true;

        resources = {
          memory = "6G";
          memoryReservation = "2G";
          cpus = "6.0";
        };
      };
    }

    {
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
    }

    {
      modules.alerting.rules."scrypted-service-down" = {
        type = "promql";
        alertname = "ScryptedServiceDown";
        expr = ''container_service_active{name="scrypted"} == 0'';
        for = "2m";
        severity = "critical";
        labels = {
          service = "scrypted";
          category = "nvr";
        };
        annotations = {
          summary = "Scrypted container is down on {{ $labels.instance }}";
          description = "Check systemctl status podman-scrypted.service and podman logs --tail=200 scrypted.";
        };
      };
    }
  ];
}
