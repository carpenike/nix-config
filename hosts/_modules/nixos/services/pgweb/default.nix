# Pgweb Service Module (Native Binary Service)
#
# This module configures Pgweb, a lightweight web-based PostgreSQL database browser.
# See: https://github.com/sosedoff/pgweb
#
# DESIGN RATIONALE (Nov 5, 2025):
# - No native NixOS module exists, so we create a custom systemd service
# - Uses native pgweb binary (not container) for simplicity and performance
# - Integrates with shared PostgreSQL instance via readonly role
# - Follows modular design patterns: reverse proxy, backup, monitoring
# - Minimal resource footprint (<50MB RAM)
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkMerge mkEnableOption mkOption mkDefault;

  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.pgweb;
in
{
  options.modules.services.pgweb = {
    enable = mkEnableOption "Pgweb PostgreSQL database browser";

    package = mkOption {
      type = lib.types.package;
      default = pkgs.pgweb;
      description = "The pgweb package to use";
    };

    port = mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Port for pgweb web interface";
    };

    listenAddress = mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address for pgweb (default localhost only)";
    };

    database = {
      host = mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "PostgreSQL host to connect to";
      };

      port = mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      user = mkOption {
        type = lib.types.str;
        default = "readonly";
        description = "PostgreSQL user for pgweb (should have read-only access)";
      };

      database = mkOption {
        type = lib.types.str;
        default = "postgres";
        description = "Default database to connect to";
      };

      passwordFile = mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing PostgreSQL password";
      };
    };

    reverseProxy = mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for pgweb";
    };

    metrics = mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Main service configuration
    {
      # Note: Pgweb uses the readonly role which should already be created by databases
      # using permissionsPolicy = "owner-readwrite+readonly-select"
      # See dispatcharr.nix for an example

      # Create systemd service for pgweb
      systemd.services.pgweb = {
        description = "Pgweb PostgreSQL Database Browser";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "postgresql.service" ];
        wants = [ "postgresql.service" ];

        serviceConfig = {
          Type = "simple";
          User = "pgweb";
          Group = "pgweb";
          Restart = "on-failure";
          RestartSec = "30s";

          # Security hardening
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          PrivateMounts = true;

          # Capabilities
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";

          # System calls
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          SystemCallErrorNumber = "EPERM";

          # Logging
          StandardOutput = "journal";
          StandardError = "journal";
        };

        script = ''
          # Read password and build connection string with URL encoding
          ${lib.optionalString (cfg.database.passwordFile != null) ''
            PASSWORD=$(cat ${cfg.database.passwordFile})
            # URL-encode the password to handle special characters like / = +
            ENCODED_PASSWORD=$(${pkgs.python3}/bin/python3 -c 'import urllib.parse; import sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PASSWORD")
            CONNECTION_URL="postgres://${cfg.database.user}:$ENCODED_PASSWORD@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.database}?sslmode=disable"
          ''}
          ${lib.optionalString (cfg.database.passwordFile == null) ''
            CONNECTION_URL="postgres://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.database}?sslmode=disable"
          ''}

          ${cfg.package}/bin/pgweb \
            --bind=${cfg.listenAddress} \
            --listen=${toString cfg.port} \
            --url="$CONNECTION_URL" \
            --readonly \
            --no-ssh
        '';
      };

      # Create system user and group
      users.users.pgweb = {
        isSystemUser = true;
        group = "pgweb";
        description = "Pgweb service user";
      };

      users.groups.pgweb = {};

      # Allow pgweb user to read password file if specified
      systemd.services.pgweb.serviceConfig.LoadCredential =
        mkIf (cfg.database.passwordFile != null)
          [ "pgpassword:${cfg.database.passwordFile}" ];
    }

    # Reverse proxy integration (Caddy)
    (mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      modules.services.caddy.virtualHosts."${cfg.reverseProxy.hostName}" = {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Pass through auth configuration if provided
        auth = cfg.reverseProxy.auth or null;

        backend = mkDefault {
          scheme = "http";
          host = cfg.listenAddress;
          port = cfg.port;
        };

        security = mkDefault {
          hsts.enable = true;
        };
      };
    })

    # Metrics integration (if enabled)
    (mkIf (cfg.metrics != null && cfg.metrics.enable) {
      # Pgweb doesn't have native metrics endpoint
      # Add systemd-based monitoring instead
      modules.alerting.rules."pgweb-down" = {
        type = "promql";
        alertname = "PgwebDown";
        expr = ''systemd_unit_state{name="pgweb.service",state="active"} != 1'';
        for = "5m";
        severity = "medium";
        labels = { service = "pgweb"; category = "availability"; };
        annotations = {
          summary = "Pgweb service is not running";
          description = "Pgweb has been down for more than 5 minutes";
        };
      };
    })
  ]);
}
