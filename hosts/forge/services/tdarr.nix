{ config, lib, ... }:
let
  serviceEnabled = config.modules.services.tdarr.enable;
in
{
  config = lib.mkMerge [
    {
      modules.services.tdarr = {
        # Tdarr - Transcoding automation
      enable = true;
      image = "ghcr.io/haveagitgat/tdarr:latest";
      nfsMountDependency = "media";
      podmanNetwork = "media-services";  # Enable DNS resolution for media library access
      healthcheck.enable = true;

      # Intel GPU hardware acceleration
      # Pass the entire /dev/dri directory to the container. This is more robust
      # than hardcoding specific device nodes, which can change between reboots.
      # The application inside the container will automatically find the correct
      # render node for VA-API transcoding.
      accelerationDevices = [ "/dev/dri" ];

      # Resource limits for transcoding workloads
      resources = {
        memory = "4G";
        memoryReservation = "2G";
        cpus = "4.0";
      };

      reverseProxy = {
        enable = true;
        hostName = "tdarr.holthome.net";
        authelia = {
          enable = true;
          instance = "main";
          authDomain = "auth.holthome.net";
          policy = "one_factor";
          allowedGroups = [ "media" ];
          allowedNetworks = [
            "172.16.0.0/12"
            "192.168.1.0/24"
            "10.0.0.0/8"
          ];
        };
      };
      backup = {
        enable = true;
        repository = "nas-primary";
        # Only backup config/database, not cache
        useSnapshots = true;
        zfsDataset = "tank/services/tdarr";
      };
      notifications.enable = true;
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ];
      };
      };
    }

    (lib.mkIf serviceEnabled {
      # Co-located Service Monitoring
      modules.alerting.rules."tdarr-service-down" = {
        type = "promql";
        alertname = "TdarrServiceInactive";
        expr = "container_service_active{name=\"tdarr\"} == 0";
        for = "2m";
        severity = "high";
        labels = { service = "tdarr"; category = "availability"; };
        annotations = {
          summary = "Tdarr service is down on {{ $labels.instance }}";
          description = "The Tdarr transcoding automation service is not active.";
          command = "systemctl status podman-tdarr.service";
        };
      };
    })
  ];
}
