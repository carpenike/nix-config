{ config, lib, ... }:
# Dispatcharr Configuration for forge
#
# IPTV stream management service
# See: https://github.com/Dispatcharr/Dispatcharr
#
# Architecture:
# - Uses shared PostgreSQL instance (main) instead of embedded database
# - Database provisioned declaratively via PostgreSQL module
# - ZFS dataset for application data
# - Backup integration via restic
# - Health monitoring and notifications
# - Caddy reverse proxy with automatic DNS registration
let
  # Centralize enable flag so database provisioning is conditional
  dispatcharrEnabled = true;  # ENABLED - shared PostgreSQL integration complete
  dispatcharrPort = 9191;
in
{
  config = lib.mkMerge [
    # Database provisioning (only when dispatcharr is enabled)
    (lib.mkIf dispatcharrEnabled {
      # Declare database requirements for dispatcharr
      # IMPORTANT: Based on Dispatcharr source code analysis, these extensions are REQUIRED:
      # - btree_gin: For GIN index support (used in Django migrations)
      # - pg_trgm: For trigram similarity searches (improves text searching)
      modules.services.postgresql.databases.dispatcharr = {
        owner = "dispatcharr";
        ownerPasswordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
        extensions = [ "btree_gin" "pg_trgm" ];
        permissionsPolicy = "owner-readwrite+readonly-select";
      };
    })

    # Reverse proxy registration using new structured config
    (lib.mkIf dispatcharrEnabled {
      modules.reverseProxy.virtualHosts.iptv = {
        enable = true;
        hostName = "iptv.${config.networking.domain}";  # iptv.holthome.net

        # Structured backend configuration
        backend = {
          scheme = "http";
          host = "localhost";
          port = dispatcharrPort;
          tls.verify = true;
        };

        # Structured security headers (backend-agnostic)
        securityHeaders = {
          X-Frame-Options = "SAMEORIGIN";
          X-Content-Type-Options = "nosniff";
          X-XSS-Protection = "1; mode=block";
          Referrer-Policy = "strict-origin-when-cross-origin";
        };

        # HSTS with standard settings
        security.hsts = {
          enable = true;
          maxAge = 15552000;  # 6 months
          includeSubDomains = true;
          preload = false;
        };

        auth = null;  # Add authentication if needed
      };
    })

    # Dispatcharr container service configuration
    # IPTV stream management
    # Now using shared PostgreSQL instance with proper integration
    {
      modules.services.dispatcharr = {
        enable = dispatcharrEnabled;

      # Database connection configuration
      database = {
        passwordFile = config.sops.secrets."postgresql/dispatcharr_password".path;
        # Other database settings use defaults: host=localhost, port=5432, name=dispatcharr, user=dispatcharr
      };

      # -- Container Image Configuration --
      # Pin to specific version for stability
      # Find releases at: https://github.com/Dispatcharr/Dispatcharr/releases
      image = "ghcr.io/dispatcharr/dispatcharr:latest";  # TODO: Pin to specific version after testing

      # dataDir defaults to /var/lib/dispatcharr (dataset mountpoint)
      healthcheck.enable = true;  # Enable container health monitoring
      backup = {
        enable = true;
        repository = "nas-primary";  # Primary NFS backup repository
      };
      notifications.enable = true;  # Enable failure notifications
      preseed = {
        enable = true;  # Enable self-healing restore
        repositoryUrl = "/mnt/nas-backup";
        passwordFile = config.sops.secrets."restic/password".path;
        # environmentFile not needed for local filesystem repository
      };
    };
    }
  ];
}
