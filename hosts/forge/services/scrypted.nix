# hosts/forge/services/scrypted.nix
#
# Host-specific configuration for Scrypted on 'forge'.
# Scrypted is a camera NVR platform with HomeKit/Google Home integration.

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
      # Stable, colon-free device aliases for the Intel iGPU (UHD 630,
      # PCI 0000:00:02.0). podman's --device flag splits on ':' to separate
      # host:container:perms, so the kernel's /dev/dri/by-path/pci-0000:00:02.0-*
      # symlinks cannot be passed directly (podman tries to stat
      # "/dev/dri/by-path/pci-0000"). These udev aliases stay PCI-stable
      # (which renderD12x number maps to Intel is NOT guaranteed across reboots)
      # while avoiding the colon-parsing problem. They are used only as the
      # podman --device *source*; see devices list below for the destination
      # naming constraint.
      services.udev.extraRules = ''
        SUBSYSTEM=="drm", KERNELS=="0000:00:02.0", KERNEL=="renderD*", SYMLINK+="dri/intel-render"
        SUBSYSTEM=="drm", KERNELS=="0000:00:02.0", KERNEL=="card*", SYMLINK+="dri/intel-card"
      '';

      modules.services.scrypted = {
        enable = true;
        hostname = serviceDomain;
        dataDir = dataDir;

        # Pass ONLY the Intel iGPU (UHD 630, i915, PCI 0000:00:02.0) for VAAPI/QSV
        # decode and Intel OpenCL. We deliberately do NOT pass the NVIDIA GPU
        # (PCI 0000:01:00.0, nouveau): libva enumerates every node in /dev/dri
        # and was loading nouveau_drv_video.so, which fails ("VAAPI connection:
        # 2 / resource allocation failed") and takes the decoder process down
        # with it (0 frames -> 0 detections).
        #
        # SOURCE: the PCI-stable udev aliases (services.udev.extraRules above) so
        # the *physical* Intel device is always selected regardless of probe order.
        #
        # DESTINATION: MUST be the Intel node's REAL host name (renderD129 / card2
        # today). The container shares the host's /sys, and libva/iHD resolves the
        # GPU by looking up /sys/class/drm/<node-name> derived from the device
        # path. If we expose the Intel device under any other name (e.g.
        # renderD128, where /sys points at the NVIDIA/nouveau card, or a custom
        # alias with no /sys entry), iHD inspects the wrong/missing sysfs node and
        # fails with "Cannot open a VA display". Scrypted enumerates /dev/dri and
        # tries every renderD* it finds, so exposing exactly renderD129 makes it
        # pick the Intel node.
        #
        # WORKAROUND (2026-06-25): VAAPI nouveau init failure on cameras.
        # Affects: Scrypted hardware decode / object detection.
        # Check: If a kernel update renumbers the DRM nodes (Intel -> renderD128),
        # update the destinations below to match the new real names; otherwise
        # scrypted falls back to (slower) software/vulkan decode rather than
        # crashing. Re-add the NVIDIA node only if/when CUDA/TensorRT passthrough
        # is wired up with proper /dev/nvidia* devices and the NVIDIA driver.
        devices = [
          "/dev/dri/intel-render:/dev/dri/renderD129" # Intel UHD 630 render node (i915, VAAPI/QSV + OpenCL)
          "/dev/dri/intel-card:/dev/dri/card2" # Intel UHD 630 card node
          "/dev/bus/usb:/dev/bus/usb" # Coral USB passthrough for TFLite delegate
        ];

        # Force libva to use the Intel iHD driver (intel-media-driver, bundled
        # in the koush/scrypted image) instead of auto-detecting nouveau.
        extraEnv = {
          LIBVA_DRIVER_NAME = "iHD";
        };

        extraOptions = [ "--shm-size=1024m" ];

        mdns = {
          enable = true;
          mode = "container"; # Run Avahi inside container - host mode has DBus permission issues
        };

        nvr = {
          enable = true;
          path = nvrPath;
          datasetName = "scrypted-nvr";
          mountMode = "rw";
          manageStorage = false; # recordings live on NAS share mounted at /mnt/data
          mountPoint = mediaMount; # assert the NFS mount itself is active before starting
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
          # Scrypted backup data is large; default 512M causes repeated OOM kills
          # (restic-backup-service-scrypted killed at ~498MB RSS on 2026-02-21)
          resources = {
            memory = "2G";
            memoryReservation = "1G";
            cpus = "2.0";
          };
          excludePatterns = [
            "${nvrPath}/**"
            "/tmp/**"
          ];
        };

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        # Resource limits - previous 1536M caused repeated OOM kills (95+ kills in Dec 2025)
        # Object detection plugins (TensorFlow/OpenCV) spike to 800MB+ per python subprocess
        # Combined with node.js runtime, 4GB was insufficient
        # Updated 2025-12-31: Increased from 2560M to 4096M (sustained high usage)
        # Updated 2026-01-09: Increased to 6GB - container hitting 83% (3.58GB/4.3GB) with OOM
        #                     events occurring on subprocesses (node killed at 11:53:14)
        resources = {
          memory = "6144M";
          memoryReservation = "3072M";
          cpus = "4.0";
        };

        # HomeKit firewall - open mDNS and HAP ports for Apple Home app access
        homekit = {
          openFirewall = true;
          hapPorts = [
            34428 # Front Door
            47163 # Driveway
            43205 # Patio
            44467 # Additional HAP accessory
            21064 # Additional HAP accessory
          ];
        };

        # MQTT integration with EMQX broker for Home Assistant
        # NOTE: This provisions the EMQX user/ACLs. You must ALSO configure the
        # MQTT plugin in Scrypted's web UI with the same broker/username/password.
        mqtt = {
          enable = true;
          server = "mqtt://127.0.0.1:1883";
          username = "scrypted";
          passwordFile = config.sops.secrets."scrypted/mqtt_password".path;
          topicPrefix = "scrypted";
          # registerEmqxIntegration = true; # default - auto-registers user + ACLs
          # Default topics: scrypted/# and homeassistant/# for HA discovery
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
