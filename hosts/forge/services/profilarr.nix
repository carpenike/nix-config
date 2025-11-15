{ config, ... }:
{
  config.modules.services = {
    # Profilarr - Profile sync for *arr services
    profilarr = {
      enable = true;
      image = "ghcr.io/profilarr/profilarr:latest";
      podmanNetwork = "media-services";  # Enable DNS resolution to *arr services (Sonarr, Radarr)

      # Run daily at 3 AM to sync quality profiles
      schedule = "*-*-* 03:00:00";

      backup = {
        enable = true;
        repository = "nas-primary";
        useSnapshots = true;
        zfsDataset = "tank/services/profilarr";
      };
      notifications.enable = true;
      preseed = {
        enable = true;
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        restoreMethods = [ "syncoid" "local" ];
      };
    };
  };

  # Co-located Service Monitoring
  config.modules.alerting.rules."profilarr-service-down" = {
    type = "promql";
    alertname = "ProfilarrServiceInactive";
    expr = "container_service_active{name=\"profilarr\"} == 0";
    for = "2m";
    severity = "high";
    labels = { service = "profilarr"; category = "availability"; };
    annotations = {
      summary = "Profilarr service is down on {{ $labels.instance }}";
      description = "The Profilarr profile sync service is not active.";
      command = "systemctl status podman-profilarr.service";
    };
  };
}
