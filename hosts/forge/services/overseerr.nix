{ config, lib, ... }:
let
  serviceEnabled = config.modules.services.overseerr.enable;
in
{
  config = lib.mkMerge [
    {
      modules.services.overseerr = {
        # Overseerr - Request management for Plex
      enable = true;
      image = "lscr.io/linuxserver/overseerr:latest";
      podmanNetwork = "media-services";  # Enable DNS resolution to Sonarr, Radarr, and Plex
      healthcheck.enable = true;

      # Ensure Overseerr starts after its dependencies to prevent connection errors during startup
      dependsOn = [ "sonarr" "radarr" ];

      reverseProxy = {
        enable = true;
        hostName = "requests.holthome.net";
        # No Authelia - Overseerr has native authentication with Plex OAuth
      };
      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/overseerr";
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
      modules.alerting.rules."overseerr-service-down" = {
        type = "promql";
        alertname = "OverseerrServiceInactive";
        expr = "container_service_active{name=\"overseerr\"} == 0";
        for = "2m";
        severity = "high";
        labels = { service = "overseerr"; category = "availability"; };
        annotations = {
          summary = "Overseerr service is down on {{ $labels.instance }}";
          description = "The Overseerr request management service is not active.";
          command = "systemctl status podman-overseerr.service";
        };
      };
    })
  ];
}
