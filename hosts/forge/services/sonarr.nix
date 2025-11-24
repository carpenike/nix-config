# hosts/forge/services/sonarr.nix
#
# Host-specific configuration for the Sonarr service on 'forge'.
# This module consumes the reusable abstraction defined in:
# hosts/_modules/nixos/services/sonarr/default.nix

{ config, lib, ... }:

let
  inherit (lib) optionalAttrs;

  serviceEnabled = config.modules.services.sonarr.enable or false;
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  config = lib.mkMerge [
    {
      modules.services.sonarr = {
        enable = true;

        # Pin container image to a specific version with a digest for immutability.
        # Renovate bot can be configured to automate updates.
        image = "ghcr.io/home-operations/sonarr:4.0.15.2940@sha256:ca6c735014bdfb04ce043bf1323a068ab1d1228eea5bab8305ca0722df7baf78";

        # Use shared NFS mount and attach to the media services network.
        nfsMountDependency = "media";
        podmanNetwork = "media-services";
        healthcheck.enable = true;

        # Reverse proxy configuration for external access via Caddy.
        reverseProxy = {
          enable = true;
          hostName = "sonarr.holthome.net";

          # Protect via Pocket ID + caddy-security; grant "media" role when the
          # upstream claim exposes the media group membership.
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

        # Enable backups via the custom backup module integration.
        backup = {
          enable = true;
          repository = "nas-primary";
          # NOTE: useSnapshots and zfsDataset are intentionally omitted.
          # The custom Sonarr module at _modules/nixos/services/sonarr/default.nix
          # already defaults these to 'true' and 'tank/services/sonarr' respectively,
          # which is the correct configuration for this host.
        };

        # Enable failure notifications via the custom notifications module.
        notifications.enable = true;

        # Enable self-healing restore from backups before service start.
        preseed = {
          enable = resticEnabled;
        } // optionalAttrs resticEnabled {
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Sonarr dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/sonarr" = {
        useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/sonarr";
          sendOptions = "wp";  # Raw encrypted send with property preservation
          recvOptions = "u";   # Don't mount on receive
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."sonarr-service-down" = {
        type = "promql";
        alertname = "SonarrServiceDown";
        expr = ''
          container_service_active{service="sonarr"} == 0
        '';
        for = "2m";
        severity = "high";
        labels = { service = "sonarr"; category = "container"; };
        annotations = {
          summary = "Sonarr service is down on {{ $labels.instance }}";
          description = "TV series management service is not running. Check: systemctl status podman-sonarr.service";
          command = "systemctl status podman-sonarr.service && journalctl -u podman-sonarr.service --since '30m'";
        };
      };
    })
  ];
}
