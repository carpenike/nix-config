{ config, lib, ... }:

let
  serviceEnabled = config.modules.services.autobrr.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.autobrr = {
        enable = true;
        image = "ghcr.io/autobrr/autobrr:latest";
        podmanNetwork = "media-services";  # Enable DNS resolution to download clients (qBittorrent, SABnzbd)
        healthcheck.enable = true;

        settings = {
          host = "0.0.0.0";
          port = 7474;
          logLevel = "INFO";
          checkForUpdates = false;  # Managed via Nix/Renovate
          sessionSecretFile = config.sops.secrets."autobrr/session-secret".path;
        };

        # Native PocketID OIDC integration
        oidc = {
          enable = true;
          issuer = "https://id.${config.networking.domain}";
          clientId = "autobrr";
          clientSecretFile = config.sops.secrets."autobrr/oidc-client-secret".path;
          redirectUrl = "https://autobrr.${config.networking.domain}/api/auth/oidc/callback";
          disableBuiltInLogin = false;
        };

        # Prometheus metrics
        metrics = {
          enable = true;
          host = "0.0.0.0";
          port = 9084;  # qui uses 9074, so use 9084 for autobrr
        };

        reverseProxy = {
          enable = true;
          hostName = "autobrr.holthome.net";
        };
        backup = {
          enable = true;
          repository = "nas-primary";
          useSnapshots = true;
          zfsDataset = "tank/services/autobrr";
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
      modules.alerting.rules."autobrr-service-down" = {
        type = "promql";
        alertname = "AutobrrServiceInactive";
        expr = "container_service_active{name=\"autobrr\"} == 0";
        for = "2m";
        severity = "high";
        labels = { service = "autobrr"; category = "availability"; };
        annotations = {
          summary = "Autobrr service is down on {{ $labels.instance }}";
          description = "The Autobrr IRC announce bot service is not active.";
          command = "systemctl status podman-autobrr.service";
        };
      };
    })
  ];
}
