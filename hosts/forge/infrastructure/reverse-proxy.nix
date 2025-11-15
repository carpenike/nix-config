{ lib, config, pkgs, ... }:

{
  # Caddy reverse proxy infrastructure configuration
  # This file contains:
  # - Environment file loading for API tokens and credentials
  # - Certificate permission management (ACLs)
  # - Systemd service and timer configurations
  #
  # Note: The main Caddy service configuration lives in the modules system.
  # This file handles host-specific operational concerns.

  # Configure Caddy to load environment files with API tokens and auth credentials
  systemd.services.caddy.serviceConfig = {
    EnvironmentFile = [
      "/run/secrets/rendered/caddy-env"
      "-/run/caddy/monitoring-auth.env"
    ];
  };

  # Separate service to fix Caddy certificate permissions
  # Runs on a timer to handle certificates created after Caddy startup
  # This is necessary because ACME certificates are created dynamically
  # and need proper group permissions for monitoring services to read them
  systemd.services.fix-caddy-cert-permissions = {
    description = "Fix Caddy certificate directory permissions";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      CERT_BASE="/var/lib/caddy/.local/share/caddy/certificates"

      # Only proceed if the directory exists
      if [ -d "$CERT_BASE" ]; then
        # Set default ACLs so new files/directories automatically inherit group permissions
        # d: = default ACLs (inherited by new files/dirs)
        # g:caddy:rX = grant caddy group read + execute (for directories only)
        ${pkgs.acl}/bin/setfacl -R -d -m g:caddy:rX "$CERT_BASE" || true

        # Apply the same ACLs to existing files/directories
        ${pkgs.acl}/bin/setfacl -R -m g:caddy:rX "$CERT_BASE" || true

        # Also fix parent directories to allow traversal
        ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local 2>/dev/null || true
        ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local/share 2>/dev/null || true
        ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local/share/caddy 2>/dev/null || true
      fi
    '';
  };

  # Timer to run permission fix periodically (every 5 minutes)
  # This ensures certificates remain accessible even after ACME renewals
  systemd.timers.fix-caddy-cert-permissions = {
    description = "Timer for fixing Caddy certificate permissions";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
      Unit = "fix-caddy-cert-permissions.service";
    };
  };

  # Create environment file from SOPS secrets
  # These are injected into the Caddy process environment for:
  # - Cloudflare DNS-01 ACME challenge authentication
  # - HTTP basic auth for monitoring UIs (Loki, pgweb)
  sops.templates."caddy-env" = {
    content = ''
      CLOUDFLARE_API_TOKEN=${lib.strings.removeSuffix "\n" config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
      CADDY_LOKI_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/loki-admin-bcrypt"}
      PGWEB_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/pgweb-admin-bcrypt"}
    '';
    owner = config.services.caddy.user;
    group = config.services.caddy.group;
  };
}
