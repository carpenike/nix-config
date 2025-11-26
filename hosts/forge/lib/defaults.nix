# hosts/forge/lib/defaults.nix
#
# Centralized defaults for forge host services.
# This file reduces duplication across service configurations by providing
# common values that are shared across multiple services.
#
# Usage:
#   let
#     forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
#   in
#   {
#     modules.services.myservice = {
#       podmanNetwork = forgeDefaults.podmanNetwork;
#       backup = forgeDefaults.backup;
#       preseed = forgeDefaults.preseed;
#       reverseProxy.caddySecurity = forgeDefaults.caddySecurity.media;
#     };
#   }

{ config, lib }:

let
  # Check if restic backup is enabled globally
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
in
{
  # =============================================================================
  # Container Networking
  # =============================================================================

  # Default Podman network for media services
  # Used by: sonarr, radarr, prowlarr, bazarr, sabnzbd, qbittorrent, overseerr, etc.
  podmanNetwork = "media-services";

  # =============================================================================
  # Backup Configuration
  # =============================================================================

  # Standard backup configuration for NAS-primary repository
  backup = {
    enable = true;
    repository = "nas-primary";
  };

  # Helper function to create backup config with ZFS snapshots
  mkBackupWithSnapshots = serviceName: {
    enable = true;
    repository = "nas-primary";
    useSnapshots = true;
    zfsDataset = "tank/services/${serviceName}";
  };

  # =============================================================================
  # Preseed / Self-Healing Configuration
  # =============================================================================

  # Standard preseed configuration for self-healing restore
  # Only enabled when restic backup is configured
  preseed = lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = "/mnt/nas-backup";
    passwordFile = config.sops.secrets."restic/password".path;
  };

  # Helper function to create preseed config with custom restore methods
  mkPreseed = restoreMethods: lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = "/mnt/nas-backup";
    passwordFile = config.sops.secrets."restic/password".path;
    restoreMethods = restoreMethods;
  };

  # =============================================================================
  # Caddy Security / Authentication
  # =============================================================================

  # Standard caddySecurity configuration using PocketID portal
  caddySecurity = {
    # Media services: requires "media" group membership
    media = {
      enable = true;
      portal = "pocketid";
      policy = "media";
      claimRoles = [
        {
          claim = "groups";
          value = "media";
          role = "media";
        }
      ];
    };

    # Admin services: requires "admin" group membership
    admin = {
      enable = true;
      portal = "pocketid";
      policy = "admin";
      claimRoles = [
        {
          claim = "groups";
          value = "admin";
          role = "admin";
        }
      ];
    };

    # Home services: requires "home" group membership
    home = {
      enable = true;
      portal = "pocketid";
      policy = "home";
      claimRoles = [
        {
          claim = "groups";
          value = "home";
          role = "home";
        }
      ];
    };
  };

  # =============================================================================
  # ZFS Replication Configuration
  # =============================================================================

  # Standard Sanoid dataset template and replication configuration
  # Used for ZFS snapshots and replication to NAS
  mkSanoidDataset = serviceName: {
    useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv/${serviceName}";
      sendOptions = "wp";  # Raw encrypted send with property preservation
      recvOptions = "u";   # Don't mount on receive
      hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
      # Consistent naming for Prometheus metrics
      targetName = "NFS";
      targetLocation = "nas-1";
    };
  };

  # =============================================================================
  # Alerting Helpers
  # =============================================================================

  # Generate a standard service-down alert for container services
  # Usage: modules.alerting.rules = forgeDefaults.mkServiceDownAlert "sonarr" "Sonarr" "TV series management";
  mkServiceDownAlert = serviceName: displayName: description: {
    type = "promql";
    alertname = "${displayName}ServiceDown";
    expr = ''container_service_active{name="${serviceName}"} == 0'';
    for = "2m";
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} service is down on {{ $labels.instance }}";
      description = "The ${displayName} ${description} service is not active.";
      command = "systemctl status podman-${serviceName}.service";
    };
  };

  # Generate alert for native systemd services (non-container)
  mkSystemdServiceDownAlert = serviceName: displayName: description: {
    type = "promql";
    alertname = "${displayName}ServiceDown";
    expr = ''node_systemd_unit_state{name="${serviceName}.service",state="active"} == 0'';
    for = "2m";
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} service is down on {{ $labels.instance }}";
      description = "The ${displayName} ${description} service is not active.";
      command = "systemctl status ${serviceName}.service";
    };
  };

  # =============================================================================
  # Common Tags
  # =============================================================================

  # Standard backup tags
  backupTags = {
    media = [ "media" "arr-services" ];
    iptv = [ "iptv" "streaming" ];
    home = [ "home-automation" ];
    infrastructure = [ "infrastructure" "critical" ];
    database = [ "database" "postgresql" ];
  };
}
