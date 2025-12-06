{ config, lib, ... }:

let
  domain = config.networking.domain;
  pocketIdBase = "https://id.${domain}";
  grafanaUrl = "https://grafana.${domain}";
  logoutRedirect = lib.strings.escapeURL grafanaUrl;
  serviceEnabled = config.modules.services.grafana.enable or false;
  # Use the new unified backup system (modules.services.backup)
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);
in
{
  config = lib.mkMerge [
    {
      # Grafana observability dashboard and visualization platform
      # Configured directly on the individual module (not through observability meta-module)
      modules.services.grafana = {
        enable = true;

        # ZFS dataset for persistence
        zfs = {
          dataset = "tank/services/grafana";
          properties = {
            compression = "zstd";
            atime = "off";
            "com.sun:auto-snapshot" = "true";
          };
        };

        # Reverse proxy configuration
        reverseProxy = {
          enable = true;
          hostName = "grafana.${domain}";
          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = 3000;
          };
          # No Caddy auth - Grafana uses OIDC authentication instead
          auth = null;
        };

        # Admin credentials
        secrets = {
          adminUser = "admin";
          adminPasswordFile = config.sops.secrets."grafana/admin-password".path;
        };

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

        # Auto-configure datasources
        autoConfigure = {
          loki = true;
          prometheus = true;
        };

        # Backup configuration
        backup = {
          enable = true;
          repository = "nas-primary";
          frequency = "daily";
          tags = [ "monitoring" "grafana" "dashboards" ];
          useSnapshots = true;
          zfsDataset = "tank/services/grafana";
          excludePatterns = [
            "**/sessions/*"
            "**/png/*"
            "**/csv/*"
            "**/pdf/*"
          ];
        };

        # Preseed for disaster recovery
        preseed = lib.mkIf resticEnabled {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          restoreMethods = [ "syncoid" "local" ];
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Grafana dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/grafana" = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = "nas-1.holthome.net";
          targetDataset = "backup/forge/zfs-recv/grafana";
          sendOptions = "w";
          recvOptions = "u";
          hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })
  ];
}
