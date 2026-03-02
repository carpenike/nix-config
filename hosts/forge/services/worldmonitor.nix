{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.worldmonitor.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.worldmonitor = {
        enable = true;
        dataDir = "/data/worldmonitor";
        datasetPath = "tank/services/worldmonitor";
        listenAddress = "127.0.0.1";
        port = 46123;

        # Cloud fallback: proxy failed local API calls to worldmonitor.app
        # Disable once all desired API keys are configured locally
        cloudFallback = true;

        # Ollama integration for AI briefs/deductions
        # Requires Ollama running on the same host or network
        ollama = {
          enable = true;
          url = "http://127.0.0.1:11434";
          model = "llama3.1:8b";
        };

        reverseProxy = {
          enable = true;
          hostName = "worldmonitor.holthome.net";
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };

        backup = forgeDefaults.mkBackupWithTags "worldmonitor" [ "worldmonitor" "dashboard" "forge" ];
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
        notifications.enable = true;

        # Secrets managed via SOPS — see hosts/forge/secrets.nix
        # Add worldmonitor API keys to the SOPS file, then reference:
        environmentFile = config.sops.secrets."worldmonitor/env".path;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for persistent state (cache, etc.)
      modules.storage.datasets.services."worldmonitor" = {
        mountpoint = "/data/worldmonitor";
        recordsize = "128K";
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        owner = config.modules.services.worldmonitor.user;
        group = config.modules.services.worldmonitor.group;
        mode = "0750";
      };

      # ZFS snapshot + replication
      modules.backup.sanoid.datasets."tank/services/worldmonitor" =
        forgeDefaults.mkSanoidDataset "worldmonitor";

      # Systemd unit down alert
      modules.alerting.rules."worldmonitor-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "worldmonitor-api" "WorldMonitor" "real-time intelligence dashboard";

      # LAN-only access — no Cloudflare tunnel

      # SOPS secret for the environment file
      sops.secrets."worldmonitor/env" = {
        sopsFile = ../secrets.sops.yaml;
        owner = config.modules.services.worldmonitor.user;
        group = config.modules.services.worldmonitor.group;
        mode = "0400";
      };
    })
  ];
}
