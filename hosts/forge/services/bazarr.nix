# hosts/forge/services/bazarr.nix
#
# Host-specific configuration for the Bazarr service on 'forge'.
# Bazarr is a subtitle manager for Sonarr and Radarr.

{ config, ... }:

{
  config.modules.services.bazarr = {
    enable = true;

    # Pin container image to specific version with digest
    image = "ghcr.io/home-operations/bazarr:1.5.3@sha256:2f1c32cb1420b2e56f60cfdf7823737eb501fdb2c13669429d23ab3a02e9ad90";

    # Bazarr needs to access both TV and movie directories
    tvDir = "/mnt/data/media/tv";
    moviesDir = "/mnt/data/media/movies";

    # Attach to media services network for DNS resolution to Sonarr and Radarr
    podmanNetwork = "media-services";
    healthcheck.enable = true;

    # Configure dependencies on Sonarr and Radarr
    # API keys are automatically injected via SOPS templates
    # Use container names for DNS resolution within media-services network
    dependencies = {
      sonarr = {
        enable = true;
        url = "http://sonarr:8989";
      };
      radarr = {
        enable = true;
        url = "http://radarr:7878";
      };
    };

    # Reverse proxy configuration for external access
    reverseProxy = {
      enable = true;
      hostName = "bazarr.holthome.net";

      # Enable Authelia SSO protection
      authelia = {
        enable = true;
        instance = "main";
        authDomain = "auth.holthome.net";
        policy = "one_factor";
        allowedGroups = [ "media" ];

        # Bypass auth for API, restrict to internal networks
        bypassPaths = [ "/api" ];
        allowedNetworks = [
          "172.16.0.0/12"  # Docker internal
          "192.168.1.0/24" # Local LAN
          "10.0.0.0/8"     # Internal private
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
  config.modules.alerting.rules."bazarr-service-down" = {
    type = "promql";
    alertname = "BazarrServiceInactive";
    expr = "container_service_active{name=\"bazarr\"} == 0";
    for = "2m";
    severity = "high";
    labels = { service = "bazarr"; category = "availability"; };
    annotations = {
      summary = "Bazarr service is down on {{ $labels.instance }}";
      description = "The Bazarr subtitle manager service is not active.";
      command = "systemctl status podman-bazarr.service";
    };
  };
}
