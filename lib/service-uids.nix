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
# UID/GID Allocation Ranges:
#   500-899:  Infrastructure services (databases, network controllers)
#   900-999:  Application services (media, monitoring, utilities)
#   65537:    Shared media group (high GID to avoid conflicts)
#
# GROUP HANDLING PATTERNS:
#   1. Shared Group: Services use a common group for file sharing (e.g., "media")
#      - Arr stack services use their own UID but share GID 65537
#      - Set `group = "media"` in service config, not a numeric GID
#   2. Matching UID/GID: Standalone services use same number for both
#      - Simpler, no file sharing needed between services
#   3. Dynamic: Native NixOS services with no ZFS may use dynamic allocation
#
# RULES:
# - NEVER reuse a UID/GID once assigned (even if service is removed)
# - ALWAYS add new services at the end of the appropriate range
# - DOCUMENT the service purpose when adding new entries
# - For arr stack: use UID from registry, but `group = "media"` (not numeric GID)
#
# Usage in service modules:
#   { lib, mylib, ... }:
#   let
#     serviceIds = mylib.serviceUids.myservice;
#   in {
#     users.users.myservice.uid = serviceIds.uid;
#     users.groups.myservice.gid = serviceIds.gid;  # Or use shared group
#   }
#
{ ... }:

{
  # ============================================================================
  # SHARED GROUPS (no associated user)
  # ============================================================================

  # Shared media group - used by arr stack, plex, etc. for shared file access
  # High GID intentionally to avoid conflicts with system groups
  mediaGroup = {
    gid = 65537;
    description = "Shared media group for arr stack, Plex, and download clients";
  };

  # ============================================================================
  # INFRASTRUCTURE SERVICES (500-599)
  # Network controllers, management interfaces
  # ============================================================================

  omada = {
    uid = 508;
    gid = 508;
    description = "TP-Link Omada network controller";
  };

  # ============================================================================
  # MEDIA AUTOMATION - ARR STACK (568, 911-923)
  # TV, movies, music, books automation
  # NOTE: sonarr and kometa share 568 - historical, both are "plex ecosystem"
  # ============================================================================

  sonarr = {
    uid = 568;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Sonarr TV show automation";
  };

  kometa = {
    uid = 568;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Kometa (formerly Plex Meta Manager) - shares UID with Sonarr";
  };

  dispatcharr = {
    uid = 569;
    gid = 569;
    description = "Dispatcharr IPTV dispatcher";
  };

  # NOTE: Arr stack services below use `group = "media"` (GID 65537) in their
  # actual config, not these per-service GIDs. The GID listed here is only for
  # reference if the service were to run standalone without shared media access.

  lidarr = {
    uid = 911;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Lidarr music automation";
  };

  readarr = {
    uid = 911;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Readarr book automation - shares UID with Lidarr (both use linuxserver.io default)";
  };

  prowlarr = {
    uid = 912;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Prowlarr indexer manager";
  };

  radarr = {
    uid = 913;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Radarr movie automation";
  };

  bazarr = {
    uid = 914;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Bazarr subtitle automation";
  };

  qbittorrent = {
    uid = 915;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "qBittorrent download client";
  };

  sabnzbd = {
    uid = 916;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "SABnzbd Usenet client";
  };

  unpackerr = {
    uid = 917;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Unpackerr archive extractor for arr stack";
  };

  profilarr = {
    uid = 918;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Profilarr quality profile manager";
  };

  autobrr = {
    uid = 919;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Autobrr torrent automation";
  };

  tdarr = {
    uid = 920;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Tdarr media transcoding";
  };

  cross-seed = {
    uid = 921;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Cross-seed torrent cross-seeding";
  };

  recyclarr = {
    uid = 922;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Recyclarr TRaSH guide sync";
  };

  seerr = {
    uid = 923;
    gid = 65537; # Uses shared media group
    groupName = "media";
    description = "Seerr (Overseerr/Jellyseerr) request management";
  };

  # ============================================================================
  # APPLICATION SERVICES (930-960)
  # Various homelab applications
  # ============================================================================

  pinchflat = {
    uid = 930;
    gid = 65537; # Uses media group for video storage
    groupName = "media";
    description = "Pinchflat YouTube archiver";
  };

  thelounge = {
    uid = 931;
    gid = 931;
    description = "The Lounge IRC client";
  };

  actual = {
    uid = 932;
    gid = 932;
    description = "Actual Budget finance app";
  };

  termix = {
    uid = 933;
    gid = 933;
    description = "Termix terminal manager";
  };

  beszel = {
    uid = 934;
    gid = 934;
    description = "Beszel monitoring hub";
  };

  beszel-agent = {
    uid = 936;
    gid = 936;
    description = "Beszel monitoring agent";
  };

  netvisor = {
    uid = 935;
    gid = 935;
    description = "Netvisor network visualization";
  };

  tracearr = {
    uid = 937;
    gid = 937;
    description = "Tracearr torrent tracker";
  };

  grafana-oncall = {
    uid = 957;
    gid = 952;
    description = "Grafana OnCall incident management";
  };

  # ============================================================================
  # UTILITY SERVICES (980-999)
  # Tools, one-off services, legacy allocations
  # ============================================================================

  qui = {
    uid = 980;
    gid = 980;
    description = "Qui service utility";
  };

  # NOTE: 999 is CONFLICTED - both unifi and onepassword-connect use it
  # TODO: Migrate one of these to a unique UID in a future update
  onepassword-connect = {
    uid = 999;
    gid = 999;
    description = "1Password Connect API (CONFLICT: shares UID with unifi)";
  };

  unifi = {
    uid = 999;
    gid = 999;
    description = "UniFi Network Controller (CONFLICT: shares UID with onepassword-connect)";
  };

  # ============================================================================
  # NEXT AVAILABLE UIDs
  # ============================================================================
  # Infrastructure (500-599): Next = 509
  # Media/Arr (568, 911-923): Next = 924
  # Applications (930-960): Next = 938
  # Utilities (980-999): Next = 981 (avoid 999 conflicts)
  #
  # ============================================================================

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

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
    version = 2;
    lastUpdated = "2026-01-02";
    conflictingUids = [ 999 ]; # Document known conflicts
    sharedUids = [ 568 911 ]; # Document intentional sharing
  };
}
