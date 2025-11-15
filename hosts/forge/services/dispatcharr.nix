{ config, lib, ... }:
# Dispatcharr Configuration for forge
#
# IPTV stream management service
# See: https://github.com/Dispatcharr/Dispatcharr
#
# Architecture:
# - Uses shared PostgreSQL instance (main) instead of embedded database
# - Database provisioned declaratively via PostgreSQL module
# - ZFS dataset for application data
# - Backup integration via restic
# - Health monitoring and notifications
# - Caddy reverse proxy with automatic DNS registration
let
  # Centralize enable flag so database provisioning is conditional
  dispatcharrEnabled = true;  # ENABLED - shared PostgreSQL integration complete
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
        enable = dispatcharrEnabled;
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
        # Other database settings use defaults: host=localhost, port=5432, name=dispatcharr, user=dispatcharr
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
      # Note: Dispatcharr uses timestamped tags (e.g., 0.10.4-20251014192218)
      # Using digest pinning for immutable references (Renovate will update both tag and digest)
      image = "ghcr.io/dispatcharr/dispatcharr:0.10.4-20251014192218@sha256:10312911e005ae39a3e814fc03cc8e36f4a92112a96dd5d898ef3cbf13791bf3";

      # dataDir defaults to /var/lib/dispatcharr (dataset mountpoint)
      healthcheck.enable = true;  # Enable container health monitoring
      backup = {
        enable = true;
        repository = "nas-primary";  # Primary NFS backup repository
        useSnapshots = true;
        zfsDataset = "tank/services/dispatcharr";
      };
      notifications.enable = true;  # Enable failure notifications
      preseed = {
        enable = true;  # Enable self-healing restore
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        # environmentFile not needed for local filesystem repository
      };
    };

  # ZFS snapshot and replication configuration for Dispatcharr dataset
  # Contributes to host-level Sanoid configuration following the contribution pattern
  modules.backup.sanoid.datasets."tank/services/dispatcharr" = {
    useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv/dispatcharr";
      sendOptions = "wp";  # Raw encrypted send with property preservation
      recvOptions = "u";   # Don't mount on receive
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
      # Consistent naming for Prometheus metrics
      targetName = "NFS";
      targetLocation = "nas-1";
    };
  };

  # Service-specific monitoring alerts
  # Contributes to host-level alerting configuration following the contribution pattern
  modules.alerting.rules."dispatcharr-service-down" = {
    type = "promql";
    alertname = "DispatcharrServiceDown";
    expr = ''
      container_service_active{service="dispatcharr"} == 0
    '';
    for = "2m";
    severity = "high";
    labels = { service = "dispatcharr"; category = "container"; };
    annotations = {
      summary = "Dispatcharr service is down on {{ $labels.instance }}";
      description = "IPTV stream management service is not running. Check: systemctl status podman-dispatcharr.service";
      command = "systemctl status podman-dispatcharr.service && journalctl -u podman-dispatcharr.service --since '30m'";
    };
  };
  }

  # If the dispatcharr container/service runs locally as a podman/docker unit,
    # allow it to access the Intel render node for VA-API without adding broad
    # privileges. This grants only the render node device; prefer DeviceAllow
    # instead of making the service user a member of the host "video" group.
    # Hardware access (DeviceAllow) is centralized via profiles/hardware/intel-gpu.nix
    # using common.intelDri.services = [ "podman-dispatcharr.service" ] on this host.
  ];
}
