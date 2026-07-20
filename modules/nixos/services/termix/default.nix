# modules/nixos/services/termix/default.nix
#
# Termix - Self-hosted SSH web terminal and server management platform
#
# Termix provides SSH terminal access, tunnel management, remote file manager,
# and server statistics through a modern web interface with native OIDC support.
#
# Reference: https://github.com/Termix-SSH/Termix
# Docs: https://docs.termix.site/
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
  serviceIds = mylib.serviceUids.termix;
  # Resolved lazily after option evaluation - safe to reference here.
  termixPort = config.modules.services.termix.port;
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "termix";
  description = "Termix";

  spec = {
    # Core service configuration.
    # Default port changed from upstream 8080 to avoid conflicts with qbittorrent.
    port = 8095;
    image = "ghcr.io/lukegus/termix:release-1.9.0@sha256:42649d815da4ee2cb71560b04a22641e54d993e05279908711d9056504487feb";
    operationalProfile = "infrastructure";
    displayName = "Termix";
    function = "ssh_management";

    startPeriod = "60s";

    # Use Node.js for the health check since the container lacks wget/curl
    healthCommand = ''node -e "fetch('http://127.0.0.1:${toString termixPort}/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"'';

    # ZFS tuning - optimal for SQLite database
    zfsRecordSize = "16K";

    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "2.0";
    };

    # Container runs as root internally because the entrypoint script needs
    # to modify nginx config. Security is maintained via:
    # 1. Container isolation
    # 2. Localhost-only port binding (127.0.0.1)
    # 3. OIDC authentication
    # The PUID/PGID injection is neutralized in extraConfig below; file
    # ownership is handled by the idmapped volume mount instead.
    runAsRoot = true;

    # Data lives at /app/data via an idmapped mount, not /config
    skipDefaultConfigMount = true;
  };

  extraOptions = {
    uid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.uid;
      description = "UID for the Termix service user (from lib/service-uids.nix).";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = serviceIds.gid;
      description = "GID for the Termix service group (from lib/service-uids.nix).";
    };

    # OIDC configuration for PocketID integration
    oidc = {
      enable = lib.mkEnableOption "OIDC authentication via PocketID";

      serverUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "OIDC issuer URL (e.g., https://id.example.com)";
        example = "https://id.holthome.net";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "termix";
        description = "OIDC client ID registered with PocketID";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing OIDC client secret";
      };

      autoRedirect = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically redirect to OIDC provider for login";
      };
    };

    # Termix exposes no Prometheus metrics endpoint - keep metrics opt-in.
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration (Termix has no native metrics)";
    };
  };

  extraConfig = cfg: {
    assertions =
      (lib.optional cfg.oidc.enable {
        assertion = cfg.oidc.serverUrl != "";
        message = "Termix oidc.enable requires oidc.serverUrl to be set.";
      })
      ++ (lib.optional cfg.oidc.enable {
        assertion = cfg.oidc.clientSecretFile != null;
        message = "Termix oidc.enable requires oidc.clientSecretFile to be set.";
      });

    virtualisation.oci-containers.containers.termix = {
      # The container runs as root internally; drop the PUID/PGID/UMASK
      # variables that the factory injects for runAsRoot containers.
      environment = lib.mkForce {
        PORT = toString cfg.port;
        TZ = cfg.timezone;
        # Disable SSL - handled by Caddy reverse proxy
        ENABLE_SSL = "false";
      };
      environmentFiles = lib.optional cfg.oidc.enable "/run/termix/oidc.env";
      # Idmapped mount: the image writes as UID 1000; map it to the termix
      # service user on the host.
      volumes = [
        "${cfg.dataDir}:/app/data:rw,idmap=uids=0-0-1#${toString cfg.uid}-1000-1;gids=0-0-1#${toString cfg.gid}-1000-1"
      ];
      # Only bind to localhost - external access goes through the reverse proxy.
      ports = lib.mkForce [
        "127.0.0.1:${toString cfg.port}:${toString cfg.port}"
      ];
    };

    # Pre-start setup: data ownership migration and OIDC environment
    systemd.services."${config.virtualisation.oci-containers.backend}-termix" = {
      serviceConfig = {
        # Create runtime directory for OIDC env file
        RuntimeDirectory = "termix";
        RuntimeDirectoryMode = "0700";
      };
      preStart = ''
        # Migrate files created by the image's UID 1000 before the idmapped mount.
        ${pkgs.coreutils}/bin/chown -R ${toString cfg.uid}:${toString cfg.gid} ${cfg.dataDir}

        ${lib.optionalString cfg.oidc.enable ''
        # Generate OIDC environment file with secret
        cat > /run/termix/oidc.env << 'EOF'
        OIDC_ENABLED=true
        OIDC_ISSUER_URL=${cfg.oidc.serverUrl}
        OIDC_CLIENT_ID=${cfg.oidc.clientId}
        OIDC_REDIRECT_URI=https://${cfg.reverseProxy.hostName or "termix.local"}/auth/callback
        OIDC_AUTO_REDIRECT=${if cfg.oidc.autoRedirect then "true" else "false"}
        EOF
        echo "OIDC_CLIENT_SECRET=$(cat ${cfg.oidc.clientSecretFile})" >> /run/termix/oidc.env
        chmod 600 /run/termix/oidc.env
        ''}
      '';
    };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."termix-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        body = ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Termix SSH web terminal service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
  };
}
