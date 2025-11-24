# hosts/forge/services/radarr.nix
#
# Host-specific configuration for the Radarr service on 'forge'.
# Radarr is a movie collection manager.

{ config, ... }:

{
  config.modules.services.radarr = {
    enable = true;

    # Pin container image to specific version with digest
    image = "ghcr.io/home-operations/radarr:6.0.3@sha256:0ebc60aa20afb0df76b52694cee846b7cf7bd96bb0157f3b68b916e77c8142a0";

    # Use shared NFS mount and attach to media services network
    nfsMountDependency = "media";
    podmanNetwork = "media-services";
    healthcheck.enable = true;

    # Reverse proxy configuration for external access
    reverseProxy = {
      enable = true;
      hostName = "radarr.holthome.net";

      # Protect via Pocket ID + caddy-security; grant media role via claim mapping
      caddySecurity = {
        enable = true;
        portal = "pocketid";
        policy = "media";
        claimRoles = [
          {
            claim = "groups";
            value = "media";
            role = "media";
          }
        ];
      };
    };

    # Enable backups
    backup = {
      enable = true;
      repository = "nas-primary";
    };

    # Enable failure notifications
    notifications.enable = true;

    # Enable self-healing restore
    preseed = {
      enable = true;
      repositoryUrl = "/mnt/nas-backup";
      passwordFile = config.sops.secrets."restic/password".path;
    };
  };

  # Co-located Service Monitoring
  config.modules.alerting.rules."radarr-service-down" = {
    type = "promql";
    alertname = "RadarrServiceInactive";
    expr = "container_service_active{name=\"radarr\"} == 0";
    for = "2m";
    severity = "high";
    labels = { service = "radarr"; category = "availability"; };
    annotations = {
      summary = "Radarr service is down on {{ $labels.instance }}";
      description = "The Radarr movie management service is not active.";
      command = "systemctl status podman-radarr.service";
    };
  };
}
