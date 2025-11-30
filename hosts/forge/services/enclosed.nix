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
  dataset = "tank/services/enclosed";
  dataDir = "/var/lib/enclosed";
  serviceEnabled = config.modules.services.enclosed.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.enclosed = {
        enable = true;
        dataDir = dataDir;
        image = "ghcr.io/corentinth/enclosed:1.9.2@sha256:be7576d6d1074698bb572162eaa5fdefaabfb1b70bcb4a936d1f46ab07051285";

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

        # Standard backup configuration
        backup = forgeDefaults.backup;

        # Preseed configuration for disaster recovery
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        # Lightweight resources - Enclosed is very small
        resources = {
          memory = "256M";
          memoryReservation = "128M";
          cpus = "0.5";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "enclosed";

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
