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
  # Uses the new unified backup system (modules.services.backup)
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);
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

  # Helper function to create backup config with ZFS snapshots and custom tags
  # Usage: forgeDefaults.mkBackupWithTags "sonarr" [ "media" "arr-services" "forge" ]
  mkBackupWithTags = serviceName: tags: {
    enable = true;
    repository = "nas-primary";
    useSnapshots = true;
    zfsDataset = "tank/services/${serviceName}";
    frequency = "daily";
    tags = tags;
  };

  # =============================================================================
  # Preseed / Self-Healing Configuration
  # =============================================================================

  # Standard preseed configuration for self-healing restore
  # Uses syncoid and local restore methods by default.
  # POLICY: Restic is intentionally excluded - offsite restic restore should be
  # a manual decision during DR scenarios, not automatic.
  # Only enabled when restic backup is configured (for repository access)
  preseed = lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = "/mnt/nas-backup";
    passwordFile = config.sops.secrets."restic/password".path;
    restoreMethods = [ "syncoid" "local" ];
  };

  # Helper function to create preseed config with custom restore methods
  # Standard usage: forgeDefaults.mkPreseed [ "syncoid" "local" ]
  # POLICY: Do not include "restic" - offsite restore is manual DR only
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
  # Static API Key Helpers
  # =============================================================================

  # Generate a static API key configuration for S2S authentication
  # These bypass caddy-security entirely and use native Caddy header matching
  #
  # Usage in service config:
  #   reverseProxy.caddySecurity = {
  #     enable = true;
  #     portal = "pocketid";
  #     policy = "admin";
  #     staticApiKeys = [
  #       (forgeDefaults.mkStaticApiKey "github-actions" "PROMETHEUS_GITHUB_API_KEY")
  #     ];
  #   };
  mkStaticApiKey = name: envVar: {
    inherit name envVar;
    headerName = "X-Api-Key";
    paths = null; # Valid for all paths
    allowedNetworks = [ ]; # Allow any source
    injectAuthHeader = true;
  };

  # Static API key with path restrictions
  # Usage: forgeDefaults.mkStaticApiKeyWithPaths "automation" "API_KEY_VAR" [ "/api" "/v1" ]
  mkStaticApiKeyWithPaths = name: envVar: paths: {
    inherit name envVar paths;
    headerName = "X-Api-Key";
    allowedNetworks = [ ];
    injectAuthHeader = true;
  };

  # Static API key with network restrictions
  # Usage: forgeDefaults.mkStaticApiKeyWithNetworks "internal-api" "INTERNAL_API_KEY" [ "10.0.0.0/8" ]
  mkStaticApiKeyWithNetworks = name: envVar: allowedNetworks: {
    inherit name envVar allowedNetworks;
    headerName = "X-Api-Key";
    paths = null;
    injectAuthHeader = true;
  };

  # Full control static API key
  # Usage: forgeDefaults.mkStaticApiKeyFull { name = "webhook"; envVar = "WEBHOOK_KEY"; paths = [ "/hook" ]; allowedNetworks = [ "192.168.0.0/16" ]; }
  mkStaticApiKeyFull = { name, envVar, headerName ? "X-Api-Key", paths ? null, allowedNetworks ? [], injectAuthHeader ? true }: {
    inherit name envVar headerName paths allowedNetworks injectAuthHeader;
  };

  # =============================================================================
  # ZFS Replication Configuration
  # =============================================================================

  # Standard Sanoid dataset template and replication configuration
  # Used for ZFS snapshots and replication to NAS
  mkSanoidDataset = serviceName: {
    useTemplate = [ "services" ]; # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
    recursive = false;
    autosnap = true;
    autoprune = true;
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv/${serviceName}";
      sendOptions = "wp"; # Raw encrypted send with property preservation
      recvOptions = "u"; # Don't mount on receive
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

  # Generate a healthcheck staleness alert for services with timer-based healthchecks
  # Fires when the last healthcheck timestamp is older than the specified threshold
  # Usage: modules.alerting.rules."plex-healthcheck-stale" = forgeDefaults.mkHealthcheckStaleAlert "plex" "Plex" 600;
  mkHealthcheckStaleAlert = serviceName: displayName: thresholdSeconds: {
    type = "promql";
    alertname = "${displayName}HealthcheckStale";
    expr = "time() - ${serviceName}_last_check_timestamp > ${toString thresholdSeconds}";
    for = "2m"; # Guard against timer jitter and brief executor delays
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} healthcheck stale on {{ $labels.instance }}";
      description = "No healthcheck updates for >${toString (thresholdSeconds / 60)} minutes. Verify timer: systemctl status ${serviceName}-healthcheck.timer";
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

  # Standard backup tags for different service categories
  # Usage: forgeDefaults.mkBackupWithTags "sonarr" (forgeDefaults.backupTags.media ++ [ "forge" ])
  backupTags = {
    media = [ "media" "arr-services" ];
    iptv = [ "iptv" "streaming" ];
    home = [ "home-automation" "home-assistant" ];
    infrastructure = [ "infrastructure" "critical" ];
    database = [ "database" "postgresql" ];
    monitoring = [ "monitoring" "observability" ];
    downloads = [ "downloads" "usenet" "torrents" ];
  };
}
