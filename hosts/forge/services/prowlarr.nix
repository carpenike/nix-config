# hosts/forge/services/prowlarr.nix
#
# Host-specific configuration for the Prowlarr service on 'forge'.
# Prowlarr is an indexer manager for *arr services.

{ config, lib, ... }:

let
  serviceEnabled = config.modules.services.prowlarr.enable or false;
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  config = lib.mkMerge [
    {
      modules.services.prowlarr = {
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
        preseed = lib.mkIf resticEnabled {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.alerting.rules."prowlarr-service-down" = {
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
    })
  ];
}
