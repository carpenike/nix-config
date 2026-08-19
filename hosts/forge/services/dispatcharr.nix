{ config, lib, pkgs, ... }:
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

  # Weekly Lineuparr re-sync (see the systemd units below).
  #
  # Requires dispatcharr/api_key in hosts/forge/secrets.sops.yaml -- sops-nix
  # fails activation for a declared-but-missing secret, so set this back to
  # false if that secret is ever removed. Rotate the key from the Dispatcharr
  # UI (Settings -> API Keys) and update the sops entry to match.
  lineupSyncEnabled = true;
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

        # Publishes the Dispatcharr Exporter plugin's /metrics endpoint so
        # Prometheus can scrape it (see infrastructure/observability/prometheus.nix).
        # The exporter surfaces EPG/M3U source status -- the signal that was
        # missing when the EPG source 404'd unnoticed for four months.
        metricsPort = 9192;

        # Raised from the 1g module default after observed OOM kills.
        #
        # At 1g, building out the channel lineup produced four
        # CONSTRAINT_MEMCG kills on 2026-08-18 (celery x3, uwsgi x1). Neither
        # container restarted and both kept reporting "healthy" -- the kernel
        # was killing worker children, which Celery/uwsgi silently respawn --
        # so the failures were invisible to systemd and to the healthcheck.
        # Symptom is a Celery task that stops making progress, not an error.
        #
        # Measured peaks under load: celery 978M, app 882M against a 1.074G
        # cap. 2g gives both real headroom for EPG imports and bulk matching
        # across ~700 channels.
        resources = {
          memory = "2g";
          memoryReservation = "512M";
          cpus = "2.0";
        };

        # Celery is a SEPARATE container with its own 1g default, and it is the
        # one that actually does the heavy lifting: XMLTV parsing, bulk channel
        # creation and EPG fuzzy-matching all run here. Three of the four OOM
        # kills above were celery (peak 978M against the 1.074G cap); raising
        # only `resources` above leaves the real offender untouched.
        celeryResources = {
          memory = "2g";
          memoryReservation = "256M";
          cpus = "2.0";
        };

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

    # Scheduled Lineuparr re-sync.
    #
    # Dispatcharr has no plugin scheduler and Lineuparr exposes no schedule
    # field, so the plugin's run endpoint is driven over HTTP instead.
    # Only apply_stream_match is scheduled.
    #
    # NOT full_sync: it recreates all 463 lineup channels and replaces stream
    # assignments on every run. Run it by hand when the lineup changes.
    #
    # NOT apply_epg_match: EPG re-matching is unscoped by country and has
    # repeatedly re-bound German channels (group GERMAN, ch 8000-8999) onto
    # US/UK guide entries -- e.g. DE Nickelodeon -> Nickelodeon.us -- because
    # it targets any channel lacking EPG and the fuzzy matcher has no country
    # gate. Those mappings were corrected by hand; running it on a timer would
    # silently undo that. Re-match EPG deliberately, scoped to one source.
    #
    # EPG source freshness is handled inside Dispatcharr by EPG Janitor's
    # watchdog (6-hourly) and deliberately has no timer here.
    (lib.mkIf (dispatcharrEnabled && lineupSyncEnabled) {
      sops.secrets."dispatcharr/api_key" = {
        mode = "0400";
        owner = "root";
        group = "root";
      };

      systemd.services.dispatcharr-lineup-sync = {
        description = "Dispatcharr Lineuparr stream re-sync";
        after = [ "network-online.target" "podman-dispatcharr.service" ];
        wants = [ "network-online.target" ];
        path = [ pkgs.curl pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "api_key:${config.sops.secrets."dispatcharr/api_key".path}"
          ];
        };
        script = ''
          set -euo pipefail
          key="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/api_key")"
          base="https://iptv.${config.networking.domain}"

          # Re-attach provider streams to existing channels as the upstream
          # M3U rotates them. Structure/EPG are intentionally left alone.
          echo "lineuparr: apply_stream_match"
          curl -fsS --max-time 900 \
            -X POST "$base/api/plugins/plugins/lineuparr/run/" \
            -H "X-API-Key: $key" \
            -H 'Content-Type: application/json' \
            -d '{"action":"apply_stream_match"}'
          echo
        '';
      };

      systemd.timers.dispatcharr-lineup-sync = {
        description = "Weekly Dispatcharr Lineuparr re-sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun 04:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
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
