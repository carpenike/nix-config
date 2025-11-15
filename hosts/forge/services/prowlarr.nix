# hosts/forge/services/prowlarr.nix
#
# Host-specific configuration for the Prowlarr service on 'forge'.
# Prowlarr is an indexer manager for *arr services.

{ config, ... }:

{
  config.modules.services.prowlarr = {
    enable = true;

    # Pin container image to specific version with digest
    image = "ghcr.io/home-operations/prowlarr:2.1.5.5216@sha256:affb671fa367f4b7029d58f4b7d04e194e887ed6af1cf5a678f3c7aca5caf6ca";

    # Attach to media services network for DNS resolution
    podmanNetwork = "media-services";
    healthcheck.enable = true;

    # Reverse proxy configuration for external access
    reverseProxy = {
      enable = true;
      hostName = "prowlarr.holthome.net";

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
  config.modules.alerting.rules."prowlarr-service-down" = {
    type = "promql";
    alertname = "ProwlarrServiceInactive";
    expr = "container_service_active{name=\"prowlarr\"} == 0";
    for = "2m";
    severity = "high";
    labels = { service = "prowlarr"; category = "availability"; };
    annotations = {
      summary = "Prowlarr service is down on {{ $labels.instance }}";
      description = "The Prowlarr indexer manager service is not active.";
      command = "systemctl status podman-prowlarr.service";
    };
  };
}
