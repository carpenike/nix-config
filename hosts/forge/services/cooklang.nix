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
{
  modules.services.cooklang = {
    enable = true;

    # Recipe directory on ZFS dataset
    recipeDir = "/data/cooklang/recipes";

    # Network configuration (localhost only, accessed via Caddy)
    listenAddress = "127.0.0.1";
    port = 9080;

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

    # Reverse proxy via Caddy with Authelia SSO
    reverseProxy = {
      enable = true;
      hostName = "recipes.holthome.net";

      # Authelia SSO protection
      authelia = {
        enable = true;
        instance = "main";
        authDomain = "auth.holthome.net";
        policy = "one_factor";  # Require authentication
        allowedGroups = [ "family" "admins" ];
      };
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

    # Disaster recovery via preseed
    preseed = {
      enable = true;
      repositoryUrl = "r2:forge-backups/cooklang";
      passwordFile = config.sops.secrets."restic/password".path;
      restoreMethods = [ "syncoid" "restic" ];
    };
  };

  # Storage configuration - ZFS dataset
  modules.storage.datasets.services.cooklang = {
    mountpoint = "/data/cooklang";
    recordsize = "128K";  # Good for text files
    compression = "zstd"; # Excellent compression for text
    properties = {
      "com.sun:auto-snapshot" = "true";  # Enable sanoid snapshots
      atime = "off";
    };
    owner = config.modules.services.cooklang.user;
    group = config.modules.services.cooklang.group;
    mode = "0750";
  };

  # Backup configuration - Sanoid snapshots
  modules.backup.sanoid.datasets."tank/services/cooklang" = {
    useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv/cooklang";
      sendOptions = "wp";  # Raw encrypted send with property preservation
      recvOptions = "u";   # Don't mount on receive
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
      # Consistent naming for Prometheus metrics
      targetName = "NFS";
      targetLocation = "nas-1";
    };
  };

  # Monitoring alerts
  modules.alerting.rules = {
    # Additional service-specific alerts can be added here
    # Core alerts (service down, dataset unavailable) are auto-configured
  };
}
