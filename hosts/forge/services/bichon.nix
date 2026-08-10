# Bichon - Self-hosted Email Archiving
#
# Rust-based email archiving system with Tantivy search engine.
# Archives emails via IMAP fetch or LMTP forwarding.
# Uses memdb for metadata, Tantivy for indexes, and bichon-blob for message data.
#
# Features:
# - Full-text search via Tantivy
# - EML storage with optional encryption
# - Web UI for browsing archived emails
# - No external database required (embedded)
#
# Security Model:
# - PocketID protects the outer HTTP boundary via caddySecurity.home
# - Bichon OSS still requires its native RBAC/WebUI login (OIDC SSO is a paid feature)
# - The native admin recovery password is stored in SOPS
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
        image = "rustmailer/bichon:2.0.1@sha256:d73d5549cd8661733b09f9ffa164eb2e6f90a6849f0480974e9ee2d9375104dc";
        publicUrl = "https://${serviceDomain}";
        encryptPasswordFile = config.sops.secrets."bichon/encrypt-password".path;

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = 15630;
          };
          # PocketID outer access gate - Bichon still enforces its native login
          caddySecurity = forgeDefaults.caddySecurity.home // {
            # Bypass PocketID auth for Bichon's OAuth2 callback
            # Microsoft redirects here after OAuth authorization
            bypassPaths = [ "/oauth2/callback" ];
          };
        };

        # Standard backup configuration
        backup = forgeDefaults.mkBackupWithSnapshots "bichon";

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

      # Root-only recovery credential for Bichon's native admin account.
      sops.secrets."bichon/admin-password" = {
        sopsFile = ../secrets.sops.yaml;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.bichon.protection = {
        class = "critical";
        objectives = {
          onsiteRpoSeconds = 900;
          offsiteRpoSeconds = 86400;
          rtoSeconds = 7200;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "offsite-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "bichon-archive";
        allowEmptyBootstrap = false;
      };

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
