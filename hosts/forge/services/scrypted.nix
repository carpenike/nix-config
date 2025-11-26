{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "scrypted.${domain}";
  dataDir = "/var/lib/scrypted";
  mediaMount =
    let
      mountCfg = config.modules.storage.nfsMounts.media or null;
    in
    if mountCfg != null && mountCfg ? localPath then mountCfg.localPath else "/mnt/data";
  nvrPath = "${mediaMount}/scrypted";
  dataset = "tank/services/scrypted";
  serviceEnabled = config.modules.services.scrypted.enable or false;
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
          # No external auth: Scrypted manages its own user database and MFA.
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

    (lib.mkIf serviceEnabled {
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "scrypted";

      modules.alerting.rules."scrypted-service-down" =
        forgeDefaults.mkServiceDownAlert "scrypted" "Scrypted" "camera NVR platform";
    })
  ];
}
