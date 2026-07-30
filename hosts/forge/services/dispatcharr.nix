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
        # DRY: derive VA-API driver from host hardware profile
        vaapiDriver = config.modules.common.intelDri.driver;
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
        image = "ghcr.io/dispatcharr/dispatcharr:0.28.2@sha256:3eb0ec779f3437ec64c08a9b3f545a355a8f512f3740cdeaac42b80f1021637d";

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
# If the dispatcharr container/service runs locally as a podman/docker unit,
# allow it to access the Intel render node for VA-API without adding broad
# privileges. This grants only the render node device; prefer DeviceAllow
# instead of making the service user a member of the host "video" group.
# Hardware access (DeviceAllow) is centralized via profiles/hardware/intel-gpu.nix
# using common.intelDri.services = [ "podman-dispatcharr.service" ] on this host.
