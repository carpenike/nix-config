# hosts/forge/services/redis.nix
#
# Centralized Redis instance for forge services.
#
# Services use different database indexes (0-15):
#   - tracearr: 0
#   - (future services can use 1, 2, etc.)
#
# Connection from containers: redis://host.containers.internal:6379/<db>
# Connection from host: redis://127.0.0.1:6379/<db>

{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.services.redis.servers.default.enable or false;

  # Redis listens on localhost and main interface for container access
  redisPort = 6379;
in
{
  config = lib.mkMerge [
    {
      # Native NixOS Redis server
      services.redis.servers.default = {
        enable = true;
        port = redisPort;

        # Bind to all interfaces - containers access via host.containers.internal
        # which resolves to the host's actual IP on the podman bridge
        # Firewall rules restrict access to localhost and podman networks
        bind = "0.0.0.0";

        # Persistence settings
        save = [
          [ 900 1 ] # Save if at least 1 key changed in 900 seconds
          [ 300 10 ] # Save if at least 10 keys changed in 300 seconds
          [ 60 10000 ] # Save if at least 10000 keys changed in 60 seconds
        ];

        # Memory management
        settings = {
          maxmemory = "256mb";
          maxmemory-policy = "allkeys-lru";

          # Append-only file for better durability
          appendonly = "yes";
          appendfsync = "everysec";

          # Logging
          loglevel = "notice";

          # Disable protected mode for container access
          # Safe because firewall restricts to podman bridge only
          protected-mode = "no";
        };
      };

      # Open firewall for podman bridge only (not external)
      networking.firewall.interfaces."podman0".allowedTCPPorts = [ redisPort ];
    }

    # Infrastructure contributions (only when enabled)
    (lib.mkIf serviceEnabled {
      # ZFS dataset for Redis persistence
      modules.storage.datasets.services.redis = {
        mountpoint = "/var/lib/redis-default";
        recordsize = "16K"; # Small writes for Redis AOF/RDB
        compression = "lz4";
        owner = "redis-default";
        group = "redis-default";
        mode = "0750";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
      };

      # Sanoid snapshot policy
      modules.backup.sanoid.datasets."tank/services/redis" =
        forgeDefaults.mkSanoidDataset "redis";

      # Service monitoring alert
      modules.alerting.rules."redis-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "redis-default" "Redis" "caching and session storage";

      # Gatus health check
      modules.services.gatus.contributions.redis = {
        name = "Redis";
        group = "Infrastructure";
        url = "tcp://127.0.0.1:${toString redisPort}";
        interval = "30s";
        conditions = [
          "[CONNECTED] == true"
        ];
      };
    })
  ];
}
