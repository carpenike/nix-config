# modules/nixos/services/enclosed/default.nix
#
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
# Security: Client-side AES-GCM encryption - server never sees plaintext
#
# Factory-based implementation (see lib/service-factory.nix).
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
  description = "Enclosed";

  spec = {
    # Core service configuration
    port = 8787;
    image = "ghcr.io/corentinth/enclosed:1.9.2@sha256:be7576d6d1074698bb572162eaa5fdefaabfb1b70bcb4a936d1f46ab07051285";
    operationalProfile = "productivity";
    displayName = "Enclosed";
    function = "note_sharing";

    healthCommand = "wget --no-verbose --spider http://127.0.0.1:8787/ || exit 1";
    startPeriod = "30s";

    # ZFS tuning - optimal for small encrypted files and SQLite
    zfsRecordSize = "16K";

    # Enclosed is very lightweight
    resources = {
      memory = "256M";
      memoryReservation = "128M";
      cpus = "0.5";
    };

    # The enclosed user was deployed with a dynamic UID/GID; the container
    # runs as its image-internal user, so no --user flag is passed (see
    # extraConfig below where the PUID/PGID injection is neutralized).
    runAsRoot = true;

    # Data lives at /app/.data, not /config
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/app/.data:rw"
    ];
  };

  extraOptions = {
    # The enclosed system user pre-dates the UID registry and is deployed
    # with a dynamically allocated UID - keep ownership operations name-based.
    user = lib.mkOption {
      type = lib.types.str;
      default = "enclosed";
      description = "User account under which Enclosed runs.";
    };

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

    # Encrypted notes are short-lived or self-destructing by design - no
    # backups (overrides the factory default of enabled).
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
      default = null;
      description = "Backup configuration for Enclosed data";
    };

    # Enclosed exposes no Prometheus metrics endpoint - keep metrics opt-in.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (Enclosed has no native metrics)";
    };
  };

  extraConfig = cfg: {
    # Preserve the dynamically allocated UID/GID of the deployed user - the
    # factory would otherwise pin them from the UID registry, breaking
    # ownership of existing data.
    users.users.enclosed.uid = lib.mkForce null;
    users.groups.enclosed.gid = lib.mkForce null;

    # The container runs as its image-internal user; drop the PUID/PGID/UMASK
    # variables that the factory injects for runAsRoot containers.
    virtualisation.oci-containers.containers.enclosed = {
      environment = lib.mkForce {
        TZ = cfg.timezone;
        # Size limits
        NOTES_MAX_ENCRYPTED_PAYLOAD_LENGTH = toString cfg.maxPayloadSize;
        # UX defaults for note creation
        PUBLIC_DEFAULT_NOTE_TTL_SECONDS = toString cfg.settings.defaultTtlSeconds;
        PUBLIC_DEFAULT_DELETE_NOTE_AFTER_READING = lib.boolToString cfg.settings.defaultDeleteAfterReading;
        PUBLIC_IS_SETTING_NO_EXPIRATION_ALLOWED = lib.boolToString cfg.settings.allowNoExpiration;
      };
      # Only bind to localhost - external access goes through the reverse proxy.
      ports = lib.mkForce [
        "127.0.0.1:${toString cfg.port}:8787"
      ];
    };

    # ZFS quota provides hard limit against abuse
    modules.storage.datasets.services.enclosed.properties = {
      "com.sun:auto-snapshot" = "true";
    } // lib.optionalAttrs (cfg.storageQuota != null) {
      quota = cfg.storageQuota;
    };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."enclosed-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        body = ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Enclosed note sharing service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
  };
}
