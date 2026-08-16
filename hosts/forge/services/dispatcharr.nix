{ config, lib, ... }:
# Dispatcharr Configuration for forge
#
# IPTV stream management service
# See: https://github.com/Dispatcharr/Dispatcharr
#
# Architecture:
# - Uses shared PostgreSQL 17 instead of the embedded database
# - Uses native Redis DB 1 and a separate non-root Celery container
# - Database provisioned declaratively via PostgreSQL module
# - ZFS dataset for application data
# - PostgreSQL durability via pgBackRest; local runtime data via ZFS snapshots
# - Health monitoring and notifications
# - Caddy reverse proxy with automatic DNS registration
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  # Centralize enable flag so database provisioning is conditional
  dispatcharrEnabled = config.modules.services.dispatcharr.enable or false;
in
{
  config = lib.mkMerge [
    # Database provisioning (only when dispatcharr is enabled)
    (lib.mkIf dispatcharrEnabled {
      # Declare database requirements for dispatcharr
      # IMPORTANT: Based on Dispatcharr source code analysis, these extensions are REQUIRED:
      # - btree_gin: For GIN index support (used in Django migrations)
      # - pg_trgm: For trigram similarity searches (improves text searching)
      modules.services.postgresql.databases.dispatcharr = {
        owner = "dispatcharr";
        ownerPasswordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
        extensions = [ "btree_gin" "pg_trgm" ];
        permissionsPolicy = "owner-readwrite+readonly-select";
      };
    })

    # Reverse proxy registration is handled automatically by the
    # dispatcharr module via modules.services.dispatcharr.reverseProxy.
    # Avoid defining a separate Caddy vhost here to prevent duplicate
    # site blocks for iptv.${config.networking.domain}.

    # Dispatcharr container service configuration
    # IPTV stream management
    # Now using shared PostgreSQL instance with proper integration
    {
      modules.services.dispatcharr = {
        enable = true;
        # DRY: derive VA-API driver and render node from the host hardware profile.
        # renderNode matters here: forge has two GPUs and /dev/dri/renderD128 is the
        # discrete NVIDIA (nouveau), not the Intel iGPU.
        vaapiDriver = config.modules.common.intelDri.driver;
        vaapiDevice = config.modules.common.intelDri.renderNode;
        # Pass the entire /dev/dri directory to the container. This is more robust
        # than hardcoding specific device nodes, which can change between reboots.
        # The application inside the container will automatically find the correct
        # render node for VA-API transcoding.
        accelerationDevices = [ "/dev/dri" ];

        # Database connection configuration
        database = {
          passwordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
          # Other settings use the external-service defaults.
        };

        # Reverse proxy integration
        # CRITICAL: Required for Django to trust X-Forwarded-* headers from Caddy
        # Without this, WebSockets and HTTPS detection will not work correctly
        reverseProxy = {
          enable = true;
          hostName = "iptv.${config.networking.domain}";
        };

        # -- Container Image Configuration --
        # Pin to specific version for stability and prevent unexpected changes
        # Find releases at: https://github.com/Dispatcharr/Dispatcharr/releases
        # Using digest pinning for immutable references (Renovate will update both tag and digest)
        image = "ghcr.io/dispatcharr/dispatcharr:0.29.0@sha256:df768adcb9993b58f5e67010cc802c8659b7f964cb1213ab7ff9bb9384db9145";

        redis.database = 1;

        # dataDir defaults to /var/lib/dispatcharr (dataset mountpoint)
        healthcheck.enable = true; # Enable container health monitoring

        backup = forgeDefaults.mkBackupWithSnapshots "dispatcharr";

        notifications.enable = true; # Enable failure notifications

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf dispatcharrEnabled {
      modules.storage.datasets.services.dispatcharr.protection = {
        class = "ephemeral";
        objectives = {
          onsiteRpoSeconds = null;
          offsiteRpoSeconds = null;
          rtoSeconds = null;
        };
        requiredTiers = [ ];
        consistency = "crash-consistent";
        validator = null;
        allowEmptyBootstrap = true;
        mechanism = {
          name = "none";
          reason = "Durable IPTV configuration lives in PostgreSQL; the mounted application dataset is empty runtime state.";
        };
      };

      # ZFS snapshot and replication configuration for Dispatcharr dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/dispatcharr" =
        forgeDefaults.mkSanoidDataset "dispatcharr";

      # Service-specific monitoring alerts
      # Contributes to host-level alerting configuration following the contribution pattern
      modules.alerting.rules."dispatcharr-service-down" =
        forgeDefaults.mkServiceDownAlert "dispatcharr" "Dispatcharr" "IPTV stream management";
    })
  ];
}
# GPU access notes:
# Dispatcharr runs as a podman container, so its render-node access comes from
# accelerationDevices above (podman --device=/dev/dri:/dev/dri:rwm), not from a
# systemd DeviceAllow. A unit-level DeviceAllow on podman-dispatcharr.service would
# have no effect on the container -- podman places the container payload in its own
# cgroup under machine.slice, outside the unit's cgroup -- which is why
# common.intelDri.services is empty for this host.
#
# Note that forge exposes two render nodes: /dev/dri/renderD128 is the discrete
# NVIDIA card (nouveau) and /dev/dri/renderD129 is the Intel UHD 630 (i915). VAAPI_DEVICE
# is derived from common.intelDri.renderNode above so it follows the host, but transcode
# profiles are stored in Dispatcharr's own database -- any profile configured in the UI
# must target renderD129 itself. See hosts/forge/services/scrypted.nix for why the
# container-visible node name has to match the real host node name.
