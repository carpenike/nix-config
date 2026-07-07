# Enclosed - Self-hostable encrypted note sharing
# https://enclosed.cc / https://github.com/CorentinTh/enclosed
#
# Design Decision: Container-based implementation
# - No native NixOS module available in nixpkgs
# - Upstream only provides container images
# - Simple stateless service with file-based storage at /app/.data
#
# Port: 8787 (HTTP)
# Data: /app/.data (SQLite database + encrypted attachments)
# Security: Client-side AES-GCM encryption - server never sees plaintext.
# The service is PUBLIC BY DESIGN: there is no auth layer in front of it.
# Security lives in the note URL (which contains the decryption key), not
# in who can reach the app. The ZFS storageQuota below is the abuse guard.
#
# Factory-based implementation (mylib.mkContainerService).
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "enclosed";
  description = "Enclosed encrypted note sharing service";

  spec = {
    description = "Enclosed encrypted note sharing service";
    port = 8787;
    image = "ghcr.io/corentinth/enclosed:1.16.0";
    category = "productivity";
    displayName = "Enclosed";
    function = "note_sharing";

    # The image entrypoint runs as root and writes /app/.data itself;
    # no --user pinning (matches the pre-factory deployment).
    runAsRoot = true;

    # Data is mounted at /app/.data, not the factory's default /config
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/app/.data:rw"
    ];

    # Image lacks curl; simple HTTP probe with wget (container listens on 8787)
    healthCommand = "wget --no-verbose --spider http://127.0.0.1:8787/ || exit 1";
    startPeriod = "30s";

    # Optimal for small encrypted files and SQLite; zstd compresses well
    zfsRecordSize = "16K";
    zfsCompression = "zstd";
    zfsProperties = {
      "com.sun:auto-snapshot" = "true";
    };

    # Enclosed is very lightweight
    resources = {
      memory = "256M";
      memoryReservation = "128M";
      cpus = "0.5";
    };

    environment = { cfg, ... }: {
      # Size limits
      NOTES_MAX_ENCRYPTED_PAYLOAD_LENGTH = toString cfg.maxPayloadSize;
      # UX defaults for note creation
      PUBLIC_DEFAULT_NOTE_TTL_SECONDS = toString cfg.settings.defaultTtlSeconds;
      PUBLIC_DEFAULT_DELETE_NOTE_AFTER_READING = lib.boolToString cfg.settings.defaultDeleteAfterReading;
      PUBLIC_IS_SETTING_NO_EXPIRATION_ALLOWED = lib.boolToString cfg.settings.allowNoExpiration;
    };
  };

  extraOptions = {
    maxPayloadSize = lib.mkOption {
      type = lib.types.int;
      default = 52428800; # 50 MB
      description = ''
        Maximum size of encrypted payload (note + attachments) in bytes.
        Default is 50 MB (52428800 bytes).
        Set to 0 to disable limit (not recommended).
      '';
      example = 104857600; # 100 MB
    };

    storageQuota = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5G";
      description = ''
        ZFS quota for the Enclosed data directory.
        Provides hard limit to prevent filesystem abuse.
        Set to null to disable quota (not recommended for public services).
      '';
      example = "10G";
    };

    # UX/Policy settings for note creation defaults
    settings = {
      defaultTtlSeconds = lib.mkOption {
        type = lib.types.enum [ 3600 86400 604800 2592000 ];
        default = 86400; # 1 day
        description = ''
          Default expiration time for new notes in seconds.
          Users can still change this when creating a note.
          Options: 3600 (1 hour), 86400 (1 day), 604800 (1 week), 2592000 (1 month)
        '';
        example = 604800; # 1 week
      };

      defaultDeleteAfterReading = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Default state of "delete after reading" checkbox for new notes.
          When enabled, notes self-destruct after first view.
        '';
      };

      allowNoExpiration = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Allow users to create notes that never expire.
          Security consideration: disabled by default to prevent orphaned data.
        '';
      };
    };
  };

  extraConfig = cfg: {
    # ZFS quota provides a hard limit against abuse on this public-by-design
    # service. Overrides the factory's mkDefault'd dataset properties so the
    # quota can be derived from cfg.storageQuota.
    modules.storage.datasets.services.enclosed.properties =
      {
        "com.sun:auto-snapshot" = "true";
      }
      // lib.optionalAttrs (cfg.storageQuota != null) {
        quota = cfg.storageQuota;
      };
  };
}
