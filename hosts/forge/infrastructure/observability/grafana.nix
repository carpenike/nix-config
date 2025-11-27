{ config, lib, ... }:

let
  domain = config.networking.domain;
  pocketIdBase = "https://id.${domain}";
  grafanaUrl = "https://grafana.${domain}";
  logoutRedirect = lib.strings.escapeURL grafanaUrl;
  serviceEnabled = config.modules.services.observability.grafana.enable or false;
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  config = lib.mkMerge [
    {
      # Grafana observability dashboard and visualization platform
      modules.services.observability.grafana = {
        enable = true;
        zfsDataset = "tank/services/grafana";
        subdomain = "grafana";
        adminUser = "admin";
        adminPasswordFile = config.sops.secrets."grafana/admin-password".path;

        # OIDC authentication via Pocket ID
        oidc = {
          enable = true;
          clientId = "grafana";
          clientSecretFile = config.sops.secrets."grafana/oidc_client_secret".path;
          authUrl = "${pocketIdBase}/authorize";
          tokenUrl = "${pocketIdBase}/api/oidc/token";
          apiUrl = "${pocketIdBase}/api/oidc/userinfo";
          scopes = [ "openid" "profile" "email" "groups" ];
          roleAttributePath = "contains(groups[*], 'admins') && 'Admin' || 'Viewer'";
          allowSignUp = false;
          signoutRedirectUrl = "${pocketIdBase}/api/oidc/end-session?post_logout_redirect_uri=${logoutRedirect}";
        };

        autoConfigure = {
          loki = true; # Auto-configure Loki data source
          prometheus = true; # Auto-configure Prometheus if available
        };
        plugins = [ ];
        preseed = lib.mkIf resticEnabled {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          restoreMethods = [ "syncoid" "local" ]; # Restic excluded: preserve ZFS lineage, use only for manual DR
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Grafana dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/grafana" = {
        useTemplate = [ "services" ]; # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/grafana";
          sendOptions = "w"; # Raw encrypted send (no property preservation)
          recvOptions = "u"; # Don't mount on receive
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          # Consistent naming for Prometheus metrics
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })
  ];
}
