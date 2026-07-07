# Termix - Self-hosted SSH web terminal and server management platform
#
# Termix provides SSH terminal access, tunnel management, remote file manager,
# and server statistics through a modern web interface with native OIDC support.
#
# Reference: https://github.com/Termix-SSH/Termix
# Docs: https://docs.termix.site/
#
# Factory-based implementation (mylib.mkContainerService).

{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  cfg = config.modules.services.termix;
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "termix";
  description = "termix SSH web terminal";

  spec = {
    description = "termix SSH web terminal";
    # Default changed from upstream 8080 to avoid conflicts with qbittorrent.
    # The container's internal PORT env var, the loopback host publish, and
    # the Caddy backend all follow cfg.port uniformly.
    port = 8095;
    image = "ghcr.io/lukegus/termix:release-1.9.0";
    category = "infrastructure";
    displayName = "Termix";
    function = "ssh_terminal";

    # Container runs as root internally because the entrypoint script needs
    # to modify the bundled nginx config. Security is maintained via:
    # 1. Container isolation (+ factory no-new-privileges)
    # 2. Localhost-only port binding (bindAddress default 127.0.0.1)
    # 3. OIDC authentication (native, via PocketID)
    runAsRoot = true;

    # Data is mounted at /app/data, not the factory's default /config
    skipDefaultConfigMount = true;
    volumes = c: [
      "${c.dataDir}:/app/data:rw"
    ];

    # Use Node.js for the health probe since the container lacks wget/curl.
    # The container listens on cfg.port (PORT env below), so the probe must
    # follow the configured port rather than a fixed containerPort.
    healthCommand = ''node -e "fetch('http://127.0.0.1:${toString cfg.port}/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"'';
    startPeriod = "60s";

    # Optimal for SQLite database
    zfsRecordSize = "16K";
    zfsCompression = "zstd";
    zfsProperties = {
      "com.sun:auto-snapshot" = "true";
    };

    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "2.0";
    };

    environment = args: {
      PORT = toString args.cfg.port;
      # Disable SSL - handled by Caddy reverse proxy
      ENABLE_SSL = "false";
    };
  };

  extraOptions = {
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
  };

  extraConfig = c: {
    assertions =
      (lib.optional c.oidc.enable {
        assertion = c.oidc.serverUrl != "";
        message = "Termix oidc.enable requires oidc.serverUrl to be set.";
      })
      ++ (lib.optional c.oidc.enable {
        assertion = c.oidc.clientSecretFile != null;
        message = "Termix oidc.enable requires oidc.clientSecretFile to be set.";
      });

    # OIDC secrets are injected via an env file generated at service start
    virtualisation.oci-containers.containers.termix.environmentFiles =
      lib.optional c.oidc.enable "/run/termix/oidc.env";

    # Pre-start setup for the OIDC environment file
    systemd.services."${config.virtualisation.oci-containers.backend}-termix" = {
      serviceConfig = {
        # Create runtime directory for OIDC env file
        RuntimeDirectory = "termix";
        RuntimeDirectoryMode = "0700";
      };
      preStart = lib.mkIf c.oidc.enable ''
        # Generate OIDC environment file with secret
        cat > /run/termix/oidc.env << 'EOF'
        OIDC_ENABLED=true
        OIDC_ISSUER_URL=${c.oidc.serverUrl}
        OIDC_CLIENT_ID=${c.oidc.clientId}
        OIDC_REDIRECT_URI=https://${c.reverseProxy.hostName or "termix.local"}/auth/callback
        OIDC_AUTO_REDIRECT=${if c.oidc.autoRedirect then "true" else "false"}
        EOF
        echo "OIDC_CLIENT_SECRET=$(cat ${c.oidc.clientSecretFile})" >> /run/termix/oidc.env
        chmod 600 /run/termix/oidc.env
      '';
    };
  };
}
