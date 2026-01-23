# lib/host-defaults.nix
#
# Parameterized host defaults factory.
# Creates a defaults library tailored to a specific host's storage and replication topology.
#
# This centralizes patterns that are identical across hosts but need host-specific values:
# - ZFS pool names and dataset paths
# - Replication targets and credentials
# - Backup repository locations
#
# Usage in host config:
#   let
#     hostDefaults = import ../../../lib/host-defaults.nix {
#       inherit config lib;
#       hostConfig = {
#         hostname = "forge";
#         zfsPool = "tank";
#         replication = {
#           targetHost = "nas-1.holthome.net";
#           targetDataset = "backup/forge/zfs-recv";
#           hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3...";
#         };
#         backup = {
#           repository = "nas-primary";
#           mountPath = "/mnt/nas-backup";
#           passwordSecret = "restic/password";
#         };
#       };
#     };
#   in
#   {
#     modules.services.myservice.backup = hostDefaults.backup;
#   }

{ config, lib, hostConfig }:

let
  # Extract host configuration with defaults
  zfsPool = hostConfig.zfsPool or "rpool";
  servicesDataset = hostConfig.servicesDataset or "${zfsPool}/services";

  # Replication configuration (optional - some hosts may not replicate)
  replication = hostConfig.replication or null;
  hasReplication = replication != null && (replication.targetHost or null) != null;

  # Backup configuration
  backupConfig = hostConfig.backup or {
    repository = "nas-primary";
    mountPath = "/mnt/nas-backup";
    passwordSecret = "restic/password";
  };

  # Check if restic backup is enabled globally
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);

  # Impermanence configuration
  impermanenceConfig = hostConfig.impermanence or {
    persistPath = "/persist";
    rootPoolName = "rpool/local/root";
    rootBlankSnapshotName = "blank";
  };
in
{
  # =============================================================================
  # Impermanence Configuration
  # =============================================================================

  # Persist path for impermanence
  persistPath = impermanenceConfig.persistPath;

  # Full impermanence settings (for modules.system.impermanence)
  impermanence = {
    rootPoolName = impermanenceConfig.rootPoolName;
    rootBlankSnapshotName = impermanenceConfig.rootBlankSnapshotName;
    persistPath = impermanenceConfig.persistPath;
  };

  # =============================================================================
  # Replication Configuration (exposed for non-service datasets)
  # =============================================================================

  # Raw replication config for use with system datasets (rpool/safe/home, etc.)
  # that don't use mkSanoidDataset. Contains all replication parameters.
  replication =
    if hasReplication then {
      targetHost = replication.targetHost;
      targetDataset = replication.targetDataset;
      sendOptions = replication.sendOptions or "wp";
      recvOptions = replication.recvOptions or "u";
      hostKey = replication.hostKey;
      targetName = replication.targetName or "NFS";
      targetLocation = replication.targetLocation or replication.targetHost;
    } else null;

  # =============================================================================
  # Container Networking
  # =============================================================================

  # Default Podman network for media services
  podmanNetwork = hostConfig.podmanNetwork or "media-services";

  # =============================================================================
  # Backup Configuration
  # =============================================================================

  # Standard backup configuration
  backup = {
    enable = true;
    repository = backupConfig.repository;
  };

  # Helper function to create backup config with ZFS snapshots
  mkBackupWithSnapshots = serviceName: {
    enable = true;
    repository = backupConfig.repository;
    useSnapshots = true;
    zfsDataset = "${servicesDataset}/${serviceName}";
  };

  # Helper function to create backup config with ZFS snapshots and custom tags
  mkBackupWithTags = serviceName: tags: {
    enable = true;
    repository = backupConfig.repository;
    useSnapshots = true;
    zfsDataset = "${servicesDataset}/${serviceName}";
    frequency = "daily";
    tags = tags;
  };

  # =============================================================================
  # Preseed / Self-Healing Configuration
  # =============================================================================

  # Standard preseed configuration for self-healing restore
  # POLICY: Restic is intentionally excluded - offsite restic restore should be
  # a manual decision during DR scenarios, not automatic.
  preseed = lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = backupConfig.mountPath;
    passwordFile = config.sops.secrets.${backupConfig.passwordSecret}.path;
    restoreMethods = [ "syncoid" "local" ];
  };

  # Helper function to create preseed config with custom restore methods
  mkPreseed = restoreMethods: lib.mkIf resticEnabled {
    enable = true;
    repositoryUrl = backupConfig.mountPath;
    passwordFile = config.sops.secrets.${backupConfig.passwordSecret}.path;
    restoreMethods = restoreMethods;
  };

  # =============================================================================
  # Caddy Security / Authentication (fully reusable - no host-specific values)
  # =============================================================================

  caddySecurity = {
    # Media services: requires "media" group membership
    media = {
      enable = true;
      portal = "pocketid";
      policy = "media";
      claimRoles = [
        { claim = "groups"; value = "media"; role = "media"; }
      ];
    };

    # Media services with API bypass: for *arr services that have built-in API key auth
    # Bypasses authentication for /api, /feed, /ping paths which are protected by the
    # service's native API key mechanism. Required for:
    # - External tools (LunaSea, Ombi, Overseerr)
    # - Inter-service communication (Prowlarr → Sonarr/Radarr)
    # - Calendar subscriptions (/feed/v3/calendar.ics)
    # - Health monitoring (/ping - intentionally unauthenticated per upstream)
    mediaWithApiBypass = {
      enable = true;
      portal = "pocketid";
      policy = "media";
      claimRoles = [
        { claim = "groups"; value = "media"; role = "media"; }
      ];
      bypassPaths = [ "/api" "/feed" "/ping" ];
    };

    # Admin services: requires "admin" group membership
    admin = {
      enable = true;
      portal = "pocketid";
      policy = "admins";
      claimRoles = [
        { claim = "groups"; value = "admin"; role = "admins"; }
      ];
    };

    # Home services: requires "home" group membership
    home = {
      enable = true;
      portal = "pocketid";
      policy = "home";
      claimRoles = [
        { claim = "groups"; value = "home"; role = "home"; }
      ];
    };
  };

  # =============================================================================
  # Static API Key Helpers (fully reusable)
  # =============================================================================

  mkStaticApiKey = name: envVar: {
    inherit name envVar;
    headerName = "X-Api-Key";
    paths = null;
    allowedNetworks = [ ];
    injectAuthHeader = true;
  };

  mkStaticApiKeyWithPaths = name: envVar: paths: {
    inherit name envVar paths;
    headerName = "X-Api-Key";
    allowedNetworks = [ ];
    injectAuthHeader = true;
  };

  mkStaticApiKeyWithNetworks = name: envVar: allowedNetworks: {
    inherit name envVar allowedNetworks;
    headerName = "X-Api-Key";
    paths = null;
    injectAuthHeader = true;
  };

  mkStaticApiKeyFull = { name, envVar, headerName ? "X-Api-Key", paths ? null, allowedNetworks ? [ ], injectAuthHeader ? true }: {
    inherit name envVar headerName paths allowedNetworks injectAuthHeader;
  };

  # =============================================================================
  # ZFS Replication Configuration
  # =============================================================================

  # Standard Sanoid dataset template and replication configuration
  mkSanoidDataset = serviceName:
    if hasReplication then {
      useTemplate = [ "services" ];
      recursive = false;
      autosnap = true;
      autoprune = true;
      replication = {
        targetHost = replication.targetHost;
        targetDataset = "${replication.targetDataset}/${serviceName}";
        sendOptions = replication.sendOptions or "wp";
        recvOptions = replication.recvOptions or "u";
        hostKey = replication.hostKey;
        targetName = replication.targetName or "NFS";
        targetLocation = replication.targetLocation or replication.targetHost;
      };
    } else {
      # No replication - just local snapshots
      useTemplate = [ "services" ];
      recursive = false;
      autosnap = true;
      autoprune = true;
    };

  # =============================================================================
  # Alerting Helpers (fully reusable)
  # =============================================================================

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

  mkHealthcheckStaleAlert = serviceName: displayName: thresholdSeconds: {
    type = "promql";
    alertname = "${displayName}HealthcheckStale";
    expr = "time() - ${serviceName}_last_check_timestamp > ${toString thresholdSeconds}";
    for = "2m";
    severity = "high";
    labels = { service = serviceName; category = "availability"; };
    annotations = {
      summary = "${displayName} healthcheck stale on {{ $labels.instance }}";
      description = "No healthcheck updates for >${toString (thresholdSeconds / 60)} minutes. Verify timer: systemctl status ${serviceName}-healthcheck.timer";
    };
  };

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
  # Common Tags (fully reusable)
  # =============================================================================

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
