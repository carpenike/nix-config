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

  # Redis listens on localhost and the podman0 bridge gateway (containers only)
  redisPort = 6379;
in
{
  config = lib.mkMerge [
    {
      # Native NixOS Redis server
      services.redis.servers.default = {
        enable = true;
        port = redisPort;

        # Bind only to localhost and the podman0 bridge gateway - containers
        # access via host.containers.internal, which resolves to 10.88.0.1 on
        # the default podman network (same pattern as PostgreSQL on this host).
        # The "-" prefix makes the bridge address optional so Redis still starts
        # if podman0 is not up yet. Previously 0.0.0.0 (LAN-reachable, only the
        # firewall stood between Redis and the network).
        bind = "127.0.0.1 -10.88.0.1";

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

          # Protected mode must stay off so containers can connect via
          # 10.88.0.1 without authentication. Exposure is limited by the
          # explicit bind list above plus the podman0-only firewall rule below.
          #
          # AUTH FOLLOW-UP (manual): Redis runs without requirepass. The only
          # consumer (tracearr) receives REDIS_URL as a plain container env
          # var from the nix store, so a password cannot be wired in cleanly
          # today. To enable auth later:
          #   1. Add a sops secret (e.g. "redis/password") to forge secrets.
          #   2. Set services.redis.servers.default.requirePassFile to it.
          #   3. Plumb the password into tracearr via an environment file
          #      (redis://:<password>@host.containers.internal:6379/0).
          protected-mode = "no";
        };
      };

      # Ensure the podman0 bridge (10.88.0.1) exists before Redis binds to it
      # (same pattern as PostgreSQL on this host).
      systemd.services.redis-default = {
        after = [ "podman.service" "sys-devices-virtual-net-podman0.device" ];
        requires = [ "sys-devices-virtual-net-podman0.device" ];
      };

      # Open firewall for podman bridge only (not external)
      networking.firewall.interfaces."podman0".allowedTCPPorts = [ redisPort ];
    }

    # Infrastructure contributions (only when enabled)
    (lib.mkIf serviceEnabled {
      # NOTE: No restic backup job on purpose - this instance holds cache and
      # session data only (tracearr sessions/caching, db 0), all of which is
      # reconstructible. AOF persistence + local sanoid snapshots (below) exist
      # solely to survive restarts without a cold cache; off-host backup would
      # add churn for no recovery value.

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
