{ lib, config, pkgs, ... }:

let
  pocketIdEnabled = config.modules.services.pocketid.enable or false;
in
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
  # - Static API keys for S2S authentication (backup scripts, etc.)
  # - Service API keys for header injection after SSO auth
  sops.templates."caddy-env" = {
    content = ''
      CLOUDFLARE_API_TOKEN=${lib.strings.removeSuffix "\n" config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
      CADDY_LOKI_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/loki-admin-bcrypt"}
      PGWEB_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/pgweb-admin-bcrypt"}
      PROMETHEUS_BACKUP_API_KEY=${lib.strings.removeSuffix "\n" config.sops.placeholder."prometheus/api-keys/backup-taskfile"}
      PAPERLESS_AI_API_KEY=${lib.strings.removeSuffix "\n" config.sops.placeholder."paperless-ai/api_key"}
      ${lib.optionalString pocketIdEnabled "CADDY_SECURITY_POCKETID_CLIENT_SECRET=${lib.strings.removeSuffix "\\n" config.sops.placeholder."caddy/pocket-id-client-secret"}"}
    '';
    owner = config.services.caddy.user;
    group = config.services.caddy.group;
  };

  # TLS/Caddy Monitoring Alerts - Co-located with reverse proxy infrastructure
  modules.alerting.rules."tls-certificate-expiring-soon" = {
    type = "promql";
    alertname = "TlsCertificateExpiringSoon";
    expr = "tls_certificate_check_success == 1 and tls_certificate_expiry_seconds < 604800"; # 7 days
    for = "5m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} ({{ $labels.certfile }}) expires in {{ $value | humanizeDuration }}. Renew soon.";
    };
  };

  modules.alerting.rules."tls-certificate-expiring-critical" = {
    type = "promql";
    alertname = "TlsCertificateExpiringCritical";
    expr = "tls_certificate_check_success == 1 and tls_certificate_expiry_seconds < 172800"; # 2 days
    for = "0m"; # Immediate alert
    severity = "critical";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate expiring very soon for {{ $labels.domain }}";
      description = "Certificate for {{ $labels.domain }} ({{ $labels.certfile }}) expires in {{ $value | humanizeDuration }}. URGENT renewal required.";
    };
  };

  modules.alerting.rules."tls-certificate-check-failed" = {
    type = "promql";
    alertname = "TlsCertificateCheckFailed";
    expr = "tls_certificate_check_success == 0";
    for = "10m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "TLS certificate check failed for {{ $labels.domain }}";
      description = "Cannot parse certificate file {{ $labels.certfile }} for domain {{ $labels.domain }}. Certificate may be malformed or unreadable.";
    };
  };

  # NOTE: Removed "acme-challenges-failing" alert (2025-11-28)
  # This alert triggered false positives because:
  # 1. We use DNS-01 ACME challenges via Cloudflare (not HTTP-01)
  # 2. External bots probe /.well-known/acme-challenge/ endpoints
  # 3. Caddy logs "no information found" for HTTP-01 lookups it can't serve
  # 4. These are NOT actual certificate failures - just bots hitting the wrong endpoint
  # Actual certificate health is monitored via tls_certificate_* metrics below.

  modules.alerting.rules."caddy-certificate-storage-missing" = {
    type = "promql";
    alertname = "CaddyCertificateStorageMissing";
    expr = "tls_certificate_check_success{domain=\"caddy.storage.missing\"} == 0";
    for = "5m";
    severity = "critical";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "Caddy certificate storage directory is missing";
      description = "The TLS metrics exporter cannot find the Caddy certificate directory. This indicates a serious configuration or storage issue.";
    };
  };

  modules.alerting.rules."tls-certificates-all-missing" = {
    type = "promql";
    alertname = "TlsCertificatesAllMissing";
    expr = ''tls_certificates_found == 0 and absent(tls_certificate_check_success{domain="caddy.storage.missing"})'';
    for = "15m";
    severity = "high";
    labels = { service = "caddy"; category = "tls"; };
    annotations = {
      summary = "No TLS certificates found in Caddy storage";
      description = "The TLS metrics exporter found 0 certificate files in the Caddy storage directory, but the directory itself exists. This might indicate a problem with Caddy's certificate management, storage, or permissions.";
    };
  };

  modules.alerting.rules."caddy-service-down" = {
    type = "promql";
    alertname = "CaddyServiceDown";
    expr = "caddy_service_up == 0";
    for = "2m";
    severity = "critical";
    labels = { service = "caddy"; category = "availability"; };
    annotations = {
      summary = "Caddy service is down";
      description = "Caddy reverse proxy is not responding. All web services may be unavailable.";
    };
  };
}
