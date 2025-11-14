{ config, ... }:
{
  config.modules.services = {
    # Autobrr - IRC announce bot for private trackers
    autobrr = {
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

      # OIDC authentication via Authelia
      oidc = {
        enable = true;
        issuer = "https://auth.${config.networking.domain}";
        clientId = "autobrr";
        clientSecretFile = config.sops.secrets."autobrr/oidc-client-secret".path;
        redirectUrl = "https://autobrr.${config.networking.domain}/api/auth/oidc/callback";
        disableBuiltInLogin = false;  # Keep built-in login as fallback
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
        authelia = {
          enable = true;
          instance = "main";
          authDomain = "auth.holthome.net";
          policy = "one_factor";
          allowedGroups = [ "media" ];
          bypassPaths = [ "/api" ];
          allowedNetworks = [
            "172.16.0.0/12"
            "192.168.1.0/24"
            "10.0.0.0/8"
          ];
        };
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
  };
}
