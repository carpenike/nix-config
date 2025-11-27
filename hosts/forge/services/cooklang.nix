{ config, lib, ... }:
# Cooklang Recipe Management Configuration for forge
#
# Provides a web-based interface for managing cooking recipes in Cooklang format.
# Cooklang is a markup language for recipes that makes it easy to manage your
# personal recipe collection as plain text files.
#
# Architecture:
# - Native Rust binary (cooklang-cli) for web server
# - Recipes stored on ZFS dataset for durability
# - Configuration files managed declaratively
# - Accessible via reverse proxy (Caddy)
# - Logs shipped to Loki
# - Automatic backup via Sanoid snapshots
# - Disaster recovery via Syncoid replication
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.cooklang.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.cooklang = {
        enable = true;

        # Recipe directory on ZFS dataset
        recipeDir = "/data/cooklang/recipes";

        # Network configuration (localhost only, accessed via Caddy)
        listenAddress = "127.0.0.1";
        port = 9085;

        # Declarative configuration
        settings = {
          # Organize ingredients by store section
          aisle = ''
            [produce]
            tomatoes
            onions
            garlic
            bell peppers
            lettuce
            spinach

            [dairy]
            milk
            cheese
            butter
            yogurt
            cream

            [meat]
            chicken
            beef
            pork
            fish

            [pantry]
            flour
            sugar
            salt
            pasta
            rice
            olive oil

            [spices]
            black pepper
            paprika
            cumin
            oregano
          '';

          # Leave pantry.conf as stateful (managed via CLI)
          # Set to null to create empty file that can be edited
          pantry = null;
        };

        # Reverse proxy via Caddy (unauthenticated by design)
        reverseProxy = {
          enable = true;
          hostName = "cook.holthome.net";
          # Intentional: no SSO guard so the shared recipe site stays public to household guests.
        };

        # Logging to Loki
        logging = {
          enable = true;
          journalUnit = "cooklang.service";
          labels = {
            service = "cooklang";
            service_type = "recipe_management";
            environment = "homelab";
          };
        };

        # Backup configuration
        backup = forgeDefaults.backup;

        # Disaster recovery via preseed
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # Storage configuration - ZFS dataset
      modules.storage.datasets.services.cooklang = {
        mountpoint = "/data/cooklang";
        recordsize = "128K"; # Good for text files
        compression = "zstd"; # Excellent compression for text
        properties = {
          "com.sun:auto-snapshot" = "true"; # Enable sanoid snapshots
          atime = "off";
        };
        owner = config.modules.services.cooklang.user;
        group = config.modules.services.cooklang.group;
        mode = "0750";
      };

      modules.services.resilioSync = {
        enable = true;
        deviceName = "${config.networking.hostName}-cooklang";
        listeningPort = 4444;

        folders.cooklang = {
          path = config.modules.services.cooklang.recipeDir;
          secretFile = config.sops.secrets."resilio/cooklang-secret".path;
          owner = config.modules.services.cooklang.user;
          group = config.modules.services.cooklang.group;
          ensurePermissions = true;
          mode = "2770";

          # Enable all discovery methods for better connectivity
          useRelayServer = true; # Helps with NAT traversal
          useTracker = true; # Public tracker for peer discovery
          useDHT = true; # Distributed peer discovery
          searchLAN = true; # Local network discovery

          # Explicit hosts for direct connection (optional but helpful)
          knownHosts = [
            "nas-1.holthome.net:4444"
            "forge.holthome.net:4444" # Add forge's own hostname for external access
          ];
        };
      };

      systemd.services.cooklang = {
        after = lib.mkAfter [ "resilio.service" ];
        wants = lib.mkAfter [ "resilio.service" ];
      };

      # Backup configuration - Sanoid snapshots
      modules.backup.sanoid.datasets."tank/services/cooklang" = forgeDefaults.mkSanoidDataset "cooklang";

      # Service availability alert
      modules.alerting.rules."cooklang-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "cooklang" "Cooklang" "recipe management";
    })
  ];
}
