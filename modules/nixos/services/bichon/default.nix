# modules/nixos/services/bichon/default.nix
#
# Bichon - Self-hosted email archiving system
# https://github.com/rustmailer/bichon
#
# Design Decision: Container-based implementation
# - No native NixOS module available in nixpkgs
# - Upstream only provides container images
# - Rust application with complex dependencies (Tantivy, bichon-blob)
#
# Port: 15630 (HTTP)
# Data: /var/lib/bichon (memdb metadata + Tantivy indexes + bichon-blob storage)
#
# Authentication: Bichon OSS always enforces its native multi-user RBAC login.
# Reverse-proxy authentication can provide an outer access gate, but native
# OIDC SSO is a Pro/Enterprise feature.
#
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  domain = config.networking.domain or "local";
  defaultHostname = "bichon.${domain}";
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "bichon";
  description = "Bichon";

  spec = {
    # Core service configuration
    port = 15630;
    # Renovate: datasource=docker depName=rustmailer/bichon
    image = "rustmailer/bichon:2.0.0@sha256:3efde2596833633398c2bba47a8c9520ff40cb05f3632d962a8386df6b327438";
    operationalProfile = "productivity";
    displayName = "Bichon";
    function = "email_archiving";

    # Health check using Bichon's status endpoint
    healthCommand = "curl -fs http://127.0.0.1:15630/api/status || exit 1";

    # ZFS tuning - optimal for SQLite metadata and Tantivy index; zstd
    # compresses email storage well.
    zfsRecordSize = "16K";

    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "1.0";
    };

    # The bichon user was deployed with a dynamic UID/GID; the container runs
    # as its image-internal user, so no --user flag is passed (see extraConfig
    # below where the PUID/PGID injection is neutralized).
    runAsRoot = true;

    # LoadCredential provides the encryption password securely; the preStart
    # script creates this env file from the credential.
    environmentFiles = [ "/run/bichon/env" ];

    # Data lives at /data, not /config
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/data:rw"
    ];
  };

  extraOptions = {
    # The bichon system user pre-dates the UID registry and is deployed with
    # a dynamically allocated UID - keep ownership operations name-based.
    user = lib.mkOption {
      type = lib.types.str;
      default = "bichon";
      description = "User account under which Bichon runs.";
    };

    encryptPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to file containing the encryption password for Bichon.
        CRITICAL: This password cannot be changed after first use.
        Changing it will make all existing encrypted data unreadable.
        Generate with: openssl rand -base64 32
      '';
      example = "/run/secrets/bichon/encrypt-password";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${defaultHostname}";
      description = ''
        Public URL where Bichon is accessible.
        Used for CORS configuration and OAuth2 redirects.
      '';
      example = "https://bichon.example.com";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Bichon log verbosity level.";
    };

    # Bichon's healthcheck uses a tighter timeout than the factory default.
    healthcheck = lib.mkOption {
      type = lib.types.nullOr mylib.types.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "5s";
        retries = 3;
        startPeriod = "30s";
      };
      description = "Container health check configuration";
    };

    # Backups are configured explicitly by hosts (overrides the factory
    # default of enabled).
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
      default = null;
      description = "Backup configuration for Bichon data";
    };

    # Bichon exposes no Prometheus metrics endpoint - keep metrics opt-in.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (Bichon has no native metrics)";
    };
  };

  extraConfig = cfg: {
    # Preserve the dynamically allocated UID/GID of the deployed user - the
    # factory would otherwise pin them from the UID registry, breaking
    # ownership of existing data.
    users.users.bichon.uid = lib.mkForce null;
    users.groups.bichon.gid = lib.mkForce null;

    # The container runs as its image-internal user; drop the PUID/PGID/UMASK
    # variables that the factory injects for runAsRoot containers.
    virtualisation.oci-containers.containers.bichon = {
      environment = lib.mkForce {
        TZ = cfg.timezone;
        # Core configuration
        BICHON_ROOT_DIR = "/data";
        BICHON_HTTP_PORT = toString cfg.port;
        BICHON_BIND_ADDR = "0.0.0.0";
        BICHON_PUBLIC_URL = cfg.publicUrl;
        BICHON_LOG_LEVEL = cfg.logLevel;
        # Disable ANSI logs for cleaner journal output
        BICHON_ANSI_LOGS = "false";
      };
      # Only bind to localhost - external access goes through the reverse proxy.
      ports = lib.mkForce [
        "127.0.0.1:${toString cfg.port}:${toString cfg.port}"
      ];
    };

    # Securely load the encryption password and create the env file consumed
    # by the container.
    systemd.services."${config.virtualisation.oci-containers.backend}-bichon" = {
      serviceConfig.LoadCredential = [
        "encrypt_password:${cfg.encryptPasswordFile}"
      ];
      preStart = ''
        # Create runtime directory
        install -d -m 700 /run/bichon
        # Create env file with encryption password from credential
        {
          printf "BICHON_ENCRYPT_PASSWORD=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/encrypt_password")"
        } > /run/bichon/env
        chmod 600 /run/bichon/env
      '';
    };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."bichon-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        body = ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Bichon email archiving service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
  };
}
