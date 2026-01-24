# Bichon - Self-hosted Email Archiving
#
# Rust-based email archiving system with Tantivy search engine.
# Archives emails via IMAP fetch or LMTP forwarding.
# Uses Native_DB for metadata and stores EML files on disk.
#
# Features:
# - Full-text search via Tantivy
# - EML storage with optional encryption
# - Web UI for browsing archived emails
# - No external database required (embedded)
#
# Security Model:
# - Internal-only access via caddySecurity.home (PocketID SSO)
# - No native multi-user support (access token is root-only)
# - Encryption password is IMMUTABLE after first use
#
# Access: Internal only at bichon.holthome.net (no Cloudflare Tunnel)

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "bichon.${domain}";
  dataset = "tank/services/bichon";
  dataDir = "/var/lib/bichon";
  serviceEnabled = config.modules.services.bichon.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.bichon = {
        enable = true;
        dataDir = dataDir;
        # renovate: depName=rustmailer/bichon datasource=docker
        image = "rustmailer/bichon:0.3.6@sha256:4b4099756e612014d9b5575a70d05971be0cfed2ac86b590fd771bb547f95c47";
        publicUrl = "https://${serviceDomain}";
        encryptPasswordFile = config.sops.secrets."bichon/encrypt-password".path;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = 15630;
          };
          # SSO authentication via PocketID - internal access only
          caddySecurity = forgeDefaults.caddySecurity.home // {
            # Bypass PocketID auth for Bichon's OAuth2 callback
            # Microsoft redirects here after OAuth authorization
            bypassPaths = [ "/oauth2/callback" ];
          };
        };

        # Standard backup configuration
        backup = forgeDefaults.backup;

        # Preseed configuration for disaster recovery
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        # Moderate resources for email archiving + full-text search
        # Tantivy indexing holds index segments in memory (~460MB steady state)
        # 768MB provides headroom for bulk imports and search operations
        resources = {
          memory = "768M";
          memoryReservation = "384M";
          cpus = "1.0";
        };
      };

      # SOPS secret for encryption password
      # IMPORTANT: This password is IMMUTABLE after first use!
      # Generate with: openssl rand -base64 32
      sops.secrets."bichon/encrypt-password" = {
        sopsFile = ../secrets.sops.yaml;
        owner = "bichon";
        group = "bichon";
        mode = "0400";
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "bichon";

      # Service availability alert
      modules.alerting.rules."bichon-service-down" =
        forgeDefaults.mkServiceDownAlert "bichon" "Bichon" "email archiving";

      # NO Cloudflare Tunnel - internal access only
      # Access via VPN or local network at bichon.holthome.net
    })
  ];
}
