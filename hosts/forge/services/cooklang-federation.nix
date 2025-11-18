{ config, ... }:
{
  modules.services.cooklangFederation = {
    enable = true;
    dataDir = "/data/cooklang-federation";
    datasetPath = "tank/services/cooklang-federation";
    listenAddress = "127.0.0.1";
    port = 9086;
    externalUrl = "https://fedcook.holthome.net";
    feedConfigFile = ../../files/cooklang-federation/feeds.yaml;

    reverseProxy = {
      enable = true;
      hostName = "fedcook.holthome.net";
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = 9086;
      };
      authelia = {
        enable = false;
        instance = "main";
        authDomain = "auth.holthome.net";
        policy = "one_factor";
        allowedGroups = [ "family" "admins" ];
        bypassPaths = [ "/static" "/favicon.ico" ];
      };
    };

    healthcheck = {
      enable = true;
      metrics.enable = true;
      interval = "5m";
      timeout = "10s";
      path = "/health";
    };

    backup = {
      enable = true;
      repository = "nas-primary";
      tags = [ "cooklang" "federation" "recipes" ];
    };

    preseed = {
      enable = true;
      repositoryUrl = "r2:forge-backups/cooklang-federation";
      passwordFile = config.sops.secrets."restic/password".path;
      restoreMethods = [ "syncoid" "restic" ];
    };

    notifications.enable = true;

    github = {
      enable = true;
      tokenFile = config.sops.secrets."github/cooklang-token".path;
    };
  };

  modules.storage.datasets.services."cooklang-federation" = {
    mountpoint = "/data/cooklang-federation";
    recordsize = "16K";
    compression = "zstd";
    properties."com.sun:auto-snapshot" = "true";
    owner = config.modules.services.cooklangFederation.user;
    group = config.modules.services.cooklangFederation.group;
    mode = "0750";
  };

  modules.backup.sanoid.datasets."tank/services/cooklang-federation" = {
    useTemplate = [ "services" ];
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv/cooklang-federation";
      sendOptions = "wp";
      recvOptions = "u";
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
      targetName = "NFS";
      targetLocation = "nas-1";
    };
  };

  modules.alerting.rules."cooklang-federation-service-down" = {
    type = "promql";
    alertname = "CooklangFederationServiceDown";
    expr = ''
      systemd_unit_state{name="cooklang-federation.service",state="active"} == 0
    '';
    for = "5m";
    severity = "high";
    labels = {
      service = "cooklang-federation";
      category = "systemd";
    };
    annotations = {
      summary = "Cooklang Federation is down";
      description = "Federation service on {{ $labels.instance }} has been down for 5 minutes";
      command = "journalctl -u cooklang-federation.service -n 200";
    };
  };

  modules.services.caddy.virtualHosts.cooklangFederation.cloudflare = {
    enable = true;
    tunnel = "forge";
  };
}
