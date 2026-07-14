# Enclosed - Encrypted Note Sharing
#
# Self-hostable encrypted note sharing service.
# Notes are encrypted client-side (AES-GCM) before transmission.
# Server never sees plaintext content.
#
# Features:
# - End-to-end encryption (zero-knowledge)
# - TTL expiration and self-destruct after reading
# - Password protection option
# - File attachments support
#
# Security Model:
# - No authentication required (by design)
# - Security is in the URL - contains the decryption key
# - Anyone with a link can read (decrypted client-side)
# - Server only stores encrypted blobs
#
# Access: Public via Cloudflare Tunnel at share.holthome.net

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "share.${domain}";
  dataDir = "/var/lib/enclosed";
  serviceEnabled = config.modules.services.enclosed.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.enclosed = {
        enable = true;
        dataDir = dataDir;
        image = "ghcr.io/corentinth/enclosed:1.16.0@sha256:d1e78c34ae7027c0c7b7a9ba67f352520049b9f260560fb8a0b3b1c55488cdc8";

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = 8787;
          };
          # No authentication - Enclosed uses client-side encryption
          # Security is in the URL (contains decryption key), not in who can access
        };

        notifications.enable = true;

        # Lightweight resources - 7d peak (25M) × 2.5 = 128M minimum
        resources = {
          memory = "128M";
          memoryReservation = "64M";
          cpus = "0.5";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.enclosed.protection = {
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
          reason = "Encrypted notes are short-lived or self-destructing; restoring retained payloads would violate their deletion semantics.";
        };
      };

      # Service availability alert
      modules.alerting.rules."enclosed-service-down" =
        forgeDefaults.mkServiceDownAlert "enclosed" "Enclosed" "encrypted note sharing";

      # Enable external access via Cloudflare Tunnel
      # Public access - anyone with a link can view notes (decryption happens client-side)
      # Authentication only required to CREATE notes (handled by caddySecurity above)
      modules.services.caddy.virtualHosts.enclosed.cloudflare = {
        enable = true;
        tunnel = "forge";
      };
    })
  ];
}
