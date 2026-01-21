# Service UID/GID Registry
#
# This file provides a centralized registry of static UIDs and GIDs for all
# service accounts in the homelab. Having stable, predictable IDs ensures:
#
# 1. ZFS datasets have consistent ownership across rebuilds
# 2. Container PUID/PGID mappings work correctly
# 3. NFS shares have proper file ownership
# 4. Backups preserve correct permissions during restore
#
# IMPORTANT: These values are derived from ACTUAL DEPLOYED VALUES on forge.
# Do not change these without also migrating the ZFS datasets and files.
#
# UID/GID Allocation Ranges (historical, actual deployments may vary):
#   < 500:    Historical NixOS defaults and system services
#   500-599:  Originally planned for infrastructure, some IoT here
#   900-929:  Media automation - arr stack
#   930-999:  Application services, observability, utilities
#   65537:    Shared media group (high GID to avoid conflicts)
#
# GROUP HANDLING PATTERNS:
#   1. Primary Group: Set via `gid` - the service's own group or shared group
#   2. Extra Groups: Set via `extraGroups` - additional group memberships
#   3. Shared Groups: Defined in `sharedGroups` with purpose and GID
#
# EXTRA GROUPS PURPOSE:
#   - media:         Access to shared media files (NFS, downloads)
#   - render:        GPU access for hardware transcoding
#   - video:         Video device access
#   - dialout:       Serial port access (USB devices, IoT)
#   - node-exporter: Write metrics to textfile collector
#   - restic-backup: (inverse) Backup user added to service groups
#
# Usage in service modules:
#   { lib, mylib, ... }:
#   let
#     serviceIds = mylib.serviceUids.myservice;
#   in {
#     users.users.myservice = {
#       uid = serviceIds.uid;
#       group = serviceIds.groupName or "myservice";
#       extraGroups = serviceIds.extraGroups or [];
#     };
#     users.groups.myservice.gid = serviceIds.gid;
#   }
#
{ ... }:

{
  # ============================================================================
  # SHARED GROUPS (infrastructure groups for cross-service access)
  # ============================================================================

  sharedGroups = {
    # Shared media group - arr stack, plex, download clients
    media = {
      gid = 65537;
      description = "Shared media group for arr stack, Plex, and download clients";
    };

    # GPU rendering access
    render = {
      gid = 303;
      description = "GPU render device access for hardware transcoding";
    };

    # Video device access
    video = {
      gid = 26;
      description = "Video device access";
    };

    # Serial port access for USB devices
    dialout = {
      gid = 27;
      description = "Serial port access for USB/IoT devices";
    };

    # Node exporter textfile collector access
    node-exporter = {
      gid = 989;
      description = "Write access to node_exporter textfile collector";
    };

    # Backup service group (services add restic-backup to their group, not vice versa)
    restic-backup = {
      gid = 983;
      description = "Restic backup service - added to service groups for read access";
    };

    # ZFS replication user
    zfs-replication = {
      gid = null; # Dynamic, but tracked here for documentation
      description = "ZFS replication service user";
    };
  };

  # Legacy alias for backward compatibility
  mediaGroup = {
    gid = 65537;
    description = "Shared media group for arr stack, Plex, and download clients";
  };

  # ============================================================================
  # HISTORICAL / NIXOS DEFAULT UIDs
  # These are NixOS upstream defaults that we preserve
  # ============================================================================

  postgres = {
    uid = 71;
    gid = 71;
    description = "PostgreSQL server - NixOS default";
    extraGroups = [ ]; # restic-backup is added to postgres group instead
  };

  plex = {
    uid = 193;
    gid = 193;
    description = "Plex Media Server - historical NixOS default UID";
    extraGroups = [ "media" "render" "video" "node-exporter" ];
  };

  grafana = {
    uid = 196;
    gid = 992;
    description = "Grafana dashboards - NixOS default UID, dynamically assigned GID";
    extraGroups = [ ];
  };

  caddy = {
    uid = 239;
    gid = 239;
    description = "Caddy web server - NixOS default";
    extraGroups = [ "node-exporter" ];
  };

  prometheus = {
    uid = 255;
    gid = 255;
    description = "Prometheus metrics collection - NixOS default";
    extraGroups = [ ];
  };

  rslsync = {
    uid = 279;
    gid = 279;
    description = "Resilio Sync - NixOS default";
    extraGroups = [ "cooklang" ]; # Access to cooklang files for sync
  };

  paperless = {
    uid = 315;
    gid = 315;
    description = "Paperless-ngx document management - NixOS default";
    extraGroups = [ ];
  };

  zigbee2mqtt = {
    uid = 317;
    gid = 317;
    description = "Zigbee2MQTT bridge - NixOS default";
    extraGroups = [ "dialout" ];
  };

  # ============================================================================
  # MEDIA AUTOMATION - ARR STACK (568, 900-929)
  # TV, movies, music, books automation
  # ============================================================================

  sonarr = {
    uid = 568;
    gid = 65537;
    groupName = "media";
    description = "Sonarr TV show automation";
    extraGroups = [ ]; # Primary group is media, no extras needed
  };

  dispatcharr = {
    uid = 569;
    gid = 569;
    description = "Dispatcharr IPTV dispatcher";
    extraGroups = [ ]; # render is conditionally added when GPU devices are configured
  };

  lidarr = {
    uid = 911;
    gid = 65537;
    groupName = "media";
    description = "Lidarr music automation";
    extraGroups = [ ];
  };

  readarr = {
    uid = 911;
    gid = 65537;
    groupName = "media";
    description = "Readarr book automation - shares UID with Lidarr";
    extraGroups = [ ];
  };

  prowlarr = {
    uid = 912;
    gid = 65537;
    groupName = "media";
    description = "Prowlarr indexer manager";
    extraGroups = [ ];
  };

  radarr = {
    uid = 913;
    gid = 65537;
    groupName = "media";
    description = "Radarr movie automation";
    extraGroups = [ ];
  };

  bazarr = {
    uid = 914;
    gid = 65537;
    groupName = "media";
    description = "Bazarr subtitle automation";
    extraGroups = [ ];
  };

  qbittorrent = {
    uid = 915;
    gid = 65537;
    groupName = "media";
    description = "qBittorrent download client";
    extraGroups = [ ];
  };

  sabnzbd = {
    uid = 916;
    gid = 65537;
    groupName = "media";
    description = "SABnzbd Usenet client";
    extraGroups = [ ];
  };

  unpackerr = {
    uid = 917;
    gid = 65537;
    groupName = "media";
    description = "Unpackerr archive extractor for arr stack";
    extraGroups = [ ];
  };

  profilarr = {
    uid = 918;
    gid = 65537;
    groupName = "media";
    description = "Profilarr quality profile manager";
    extraGroups = [ ];
  };

  autobrr = {
    uid = 919;
    gid = 65537;
    groupName = "media";
    description = "Autobrr torrent automation";
    extraGroups = [ ];
  };

  tdarr = {
    uid = 920;
    gid = 65537;
    groupName = "media";
    description = "Tdarr media transcoding";
    extraGroups = [ ]; # render is conditionally added when GPU devices are configured
  };

  cross-seed = {
    uid = 921;
    gid = 65537;
    groupName = "media";
    description = "Cross-seed torrent cross-seeding";
    extraGroups = [ ];
  };

  recyclarr = {
    uid = 922;
    gid = 65537;
    groupName = "media";
    description = "Recyclarr TRaSH guide sync";
    extraGroups = [ ];
  };

  seerr = {
    uid = 923;
    gid = 65537;
    groupName = "media";
    description = "Seerr (Overseerr/Jellyseerr) request management";
    extraGroups = [ ];
  };

  # ============================================================================
  # APPLICATION SERVICES (930-999)
  # Various homelab applications - UIDs from actual deployment
  # ============================================================================

  pinchflat = {
    uid = 930;
    gid = 65537;
    groupName = "media";
    description = "Pinchflat YouTube archiver";
    extraGroups = [ ];
  };

  thelounge = {
    uid = 931;
    gid = 931;
    description = "The Lounge IRC client";
    extraGroups = [ ];
  };

  actual = {
    uid = 932;
    gid = 932;
    description = "Actual Budget finance app";
    extraGroups = [ ];
  };

  termix = {
    uid = 933;
    gid = 933;
    description = "Termix terminal manager";
    extraGroups = [ ];
  };

  beszel = {
    uid = 934;
    gid = 934;
    description = "Beszel monitoring hub";
    extraGroups = [ ];
  };

  netvisor = {
    uid = 935;
    gid = 935;
    description = "Netvisor network visualization";
    extraGroups = [ ];
  };

  beszel-agent = {
    uid = 936;
    gid = 936;
    description = "Beszel monitoring agent";
    extraGroups = [ ];
  };

  tracearr = {
    uid = 937;
    gid = 937;
    description = "Tracearr torrent tracker";
    extraGroups = [ ];
  };

  apprise = {
    uid = 938;
    gid = 938;
    description = "Apprise API notification gateway";
    extraGroups = [ ];
  };

  grafana-oncall = {
    uid = 957;
    gid = 952;
    description = "Grafana OnCall incident management";
    extraGroups = [ ];
  };

  kometa = {
    uid = 959;
    gid = 65537;
    groupName = "media";
    description = "Kometa (Plex Meta Manager) - Plex metadata automation";
    extraGroups = [ ];
  };

  litellm = {
    uid = 961;
    gid = 955;
    description = "LiteLLM proxy for LLM APIs";
    extraGroups = [ ];
  };

  open-webui = {
    uid = 962;
    gid = 956;
    description = "Open WebUI for LLM interfaces";
    extraGroups = [ ];
  };

  homepage = {
    uid = 965;
    gid = 959;
    description = "Homepage dashboard";
    extraGroups = [ ];
  };

  gatus = {
    uid = 966;
    gid = 960;
    description = "Gatus health check monitoring";
    extraGroups = [ ];
  };

  glances = {
    uid = 967;
    gid = 961;
    description = "Glances system monitoring";
    extraGroups = [ ];
  };

  tautulli = {
    uid = 968;
    gid = 962;
    description = "Tautulli Plex analytics";
    extraGroups = [ ];
  };

  esphome = {
    uid = 969;
    gid = 963;
    description = "ESPHome device manager";
    extraGroups = [ ];
  };

  pocketid = {
    uid = 970;
    gid = 964;
    description = "PocketID OIDC authentication provider";
    extraGroups = [ ];
  };

  zwave-js-ui = {
    uid = 971;
    gid = 965;
    description = "Z-Wave JS UI controller";
    extraGroups = [ "dialout" ];
  };

  frigate = {
    uid = 973;
    gid = 967;
    description = "Frigate NVR for video surveillance";
    extraGroups = [ "render" "video" "coral" ];
  };

  teslamate = {
    uid = 975;
    gid = 970;
    description = "TeslaMate vehicle data logger";
    extraGroups = [ ];
  };

  cooklang-federation = {
    uid = 978;
    gid = 973;
    description = "Cooklang federation service";
    extraGroups = [ "node-exporter" ]; # Health check metrics
  };

  cooklang = {
    uid = 979;
    gid = 973; # Shares group with cooklang-federation
    description = "Cooklang recipe server";
    extraGroups = [ ];
  };

  tqm = {
    uid = 981;
    gid = 974;
    description = "TQM torrent queue manager";
    extraGroups = [ "media" ]; # Needs access to media files
  };

  cloudflared = {
    uid = 983;
    gid = 976;
    description = "Cloudflare tunnel daemon";
    extraGroups = [ ];
  };

  promtail = {
    uid = 990;
    gid = 984;
    description = "Promtail log shipper";
    extraGroups = [ "systemd-journal" ]; # Read journal logs
  };

  loki = {
    uid = 994;
    gid = 990;
    description = "Loki log aggregation";
    extraGroups = [ ];
  };

  alertmanager = {
    uid = 995;
    gid = 993;
    description = "Alertmanager alert routing";
    extraGroups = [ ];
  };

  tududi = {
    uid = 996;
    gid = 996;
    description = "Tududi productivity and task management";
    extraGroups = [ ];
  };

  # ============================================================================
  # SERVICES NOT YET DEPLOYED (placeholders for future use)
  # These use idealized allocations - update when actually deployed
  # ============================================================================

  mealie = {
    uid = 500;
    gid = 500;
    description = "Mealie recipe manager (not yet deployed)";
    extraGroups = [ ];
  };

  emqx = {
    uid = 505;
    gid = 505;
    description = "EMQX MQTT broker (not yet deployed)";
    extraGroups = [ ];
  };

  omada = {
    uid = 508;
    gid = 508;
    description = "TP-Link Omada network controller (not yet deployed)";
    extraGroups = [ ];
  };

  unifi = {
    uid = 509;
    gid = 509;
    description = "UniFi Network Controller (not yet deployed)";
    extraGroups = [ ];
  };

  home-assistant = {
    uid = 286;
    gid = 286;
    description = "Home Assistant home automation";
    extraGroups = [ "dialout" ]; # USB device access
  };

  scrypted = {
    uid = 555;
    gid = 555;
    description = "Scrypted home automation bridge (not yet deployed)";
    extraGroups = [ "render" "video" ];
  };

  go2rtc = {
    uid = 556;
    gid = 556;
    description = "go2rtc streaming server (not yet deployed)";
    extraGroups = [ "render" "video" ];
  };

  miniflux = {
    uid = 651;
    gid = 651;
    description = "Miniflux RSS reader (not yet deployed)";
    extraGroups = [ ];
  };

  attic = {
    uid = 652;
    gid = 652;
    description = "Attic binary cache server (not yet deployed)";
    extraGroups = [ ];
  };

  pgweb = {
    uid = 985;
    gid = 979;
    description = "Pgweb PostgreSQL browser";
    extraGroups = [ ];
  };

  enclosed = {
    uid = 941;
    gid = 941;
    description = "Enclosed secure note sharing (not yet deployed)";
    extraGroups = [ ];
  };

  bichon = {
    uid = 944;
    gid = 944;
    description = "Bichon service (not yet deployed)";
    extraGroups = [ ];
  };

  coachiq = {
    uid = 945;
    gid = 945;
    description = "CoachIQ RV monitoring (not yet deployed)";
    extraGroups = [ ];
  };

  n8n = {
    uid = 939;
    gid = 939;
    description = "n8n workflow automation (not yet deployed)";
    extraGroups = [ ];
  };

  qui = {
    uid = 980;
    gid = 980;
    description = "Qui service utility (not yet deployed)";
    extraGroups = [ ];
  };

  onepassword-connect = {
    uid = 982;
    gid = 982;
    description = "1Password Connect API (not yet deployed)";
    extraGroups = [ ];
  };

  # ============================================================================
  # NEXT AVAILABLE UIDs (for new deployments)
  # ============================================================================
  # When adding a new service, use the next available UID in the 996+ range
  # and document the actual deployed values after first deployment.
  #
  # Next available: 996
  # ============================================================================

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  # Generate user configuration from service definition
  # Usage: mylib.serviceUids.mkUserConfig "sonarr" { isSystemUser = true; home = "/var/lib/sonarr"; }
  # Returns: { uid, group, extraGroups, isSystemUser, ... }
  mkUserConfig = serviceName: extraAttrs: serviceEntry:
    let
      base = {
        uid = serviceEntry.uid;
        group = serviceEntry.groupName or serviceName;
        extraGroups = serviceEntry.extraGroups or [ ];
        description = serviceEntry.description or "${serviceName} service user";
      };
    in
    base // extraAttrs;

  # Get the list of groups a backup user should be added to
  # Usage: mylib.serviceUids.getBackupGroups [ "sonarr" "radarr" "plex" ]
  # Returns: [ "sonarr" "radarr" "plex" ] (group names, not GIDs)
  getBackupGroups = serviceNames: serviceNames;

  # Get the extraGroups for a service, with optional additions
  # Usage: mylib.serviceUids.getExtraGroups "plex" [ "additional-group" ]
  getExtraGroups = serviceName: additionalGroups: self:
    let
      serviceEntry = self.${serviceName} or { extraGroups = [ ]; };
      baseGroups = serviceEntry.extraGroups or [ ];
    in
    baseGroups ++ additionalGroups;

  # Generate an assertion that a group exists
  # Usage: mylib.serviceUids.mkGroupExistsAssertion config "media" "sonarr"
  mkGroupExistsAssertion = config: groupName: serviceName: {
    assertion = config.users.groups ? ${groupName};
    message = ''
      Service '${serviceName}' requires group '${groupName}' but it is not defined.
      Either:
        1. Enable modules.users.sharedGroups.enable = true (recommended)
        2. Define users.groups.${groupName} manually
    '';
  };

  # Generate an assertion that a user exists
  # Usage: mylib.serviceUids.mkUserExistsAssertion config "sonarr" "sonarr"
  mkUserExistsAssertion = config: userName: serviceName: {
    assertion = config.users.users ? ${userName};
    message = ''
      Service '${serviceName}' requires user '${userName}' but it is not defined.
      The service module should create this user automatically.
    '';
  };

  # ============================================================================
  # METADATA
  # ============================================================================

  _meta = {
    version = 5;
    lastUpdated = "2026-01-03";
    lastAuditedAgainst = "forge.holthome.net";
    sharedUids = [ 911 ]; # Document intentional sharing (lidarr/readarr)
    sharedGids = [ 973 ]; # cooklang and cooklang-federation share a group
    changes = [
      "v5: Added extraGroups to all service entries"
      "v5: Added sharedGroups section for infrastructure groups"
      "v5: Added helper functions mkUserConfig, getExtraGroups, getBackupGroups"
    ];
  };
}
