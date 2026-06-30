# CoachIQ — RV-C / multi-protocol CANbus monitoring for the RV Raspberry Pi.
#
# Consumes the upstream hybrid NixOS module (carpenike/coachiq, post-HOF-020).
# The module owns the coachiq user/group, the systemd unit, tmpfiles, and the
# COACHIQ_* environment contract. We set only the load-bearing first-class
# options here and deliver the production security secret through sops-nix.
#
# Secrets MUST NOT live in Nix options, services.coachiq.settings, the Nix
# store, or systemd Environment=. The security secret is delivered via a
# root-readable EnvironmentFile rendered from sops at activation time.
{ pkgs
, config
, inputs
, mylib
, ...
}:
let
  coachiqPackage = inputs.coachiq.packages.${pkgs.stdenv.hostPlatform.system}.coachiq.overridePythonAttrs (old: {
    # WORKAROUND (2026-06-29): CoachIQ rev f569955 security validator references
    # stale AuthenticationSettings fields. Tracked in docs/workarounds.md.
    postPatch = (old.postPatch or "") + ''
      substituteInPlace backend/core/security_config_validator.py \
        --replace-fail 'self.settings.auth.access_token_expire_minutes' 'self.settings.auth.jwt_expire_minutes' \
        --replace-fail 'self.settings.auth.mode' 'getattr(self.settings.auth, "mode", "none")' \
        --replace-fail 'self.settings.auth.admin_password_hash' 'self.settings.auth.admin_password' \
        --replace-fail 'self.settings.auth.enable_magic_link' 'self.settings.auth.enable_magic_links'
    '';
  });
in
{
  imports = [
    inputs.coachiq.nixosModules.default
  ];

  config = {
    services.coachiq = {
      enable = true;
      package = coachiqPackage;

      # Bind to loopback. No coachiq reverse-proxy vhost is wired on nixpi yet,
      # so the port stays host-local. Switch to a routable address (and add a
      # Caddy vhost / openFirewall) when external access is intended.
      host = "127.0.0.1";
      port = 8000;
      dataDir = "/var/lib/coachiq";
      logLevel = "INFO";

      # No TLS-terminating reverse proxy fronts coachiq on nixpi yet; keep the
      # app's TLS-redirect/HSTS behaviour off. Flip to true once Caddy fronts it.
      tlsTerminationIsExternal = false;
      openFirewall = false;

      # Root-readable EnvironmentFile carrying COACHIQ_SECURITY__SECRET_KEY.
      # Rendered by sops-nix at activation (see sops.secrets below).
      environmentFile = config.sops.secrets.coachiq_environment.path;

      # Non-secret long-tail COACHIQ_* settings (full env var names) go here.
      # Left empty: upstream defaults (single can0 interface, auth disabled,
      # mandatory persistence) are correct for the initial deployment. Add e.g.
      # COACHIQ_CAN__INTERFACES / COACHIQ_CAN__INTERFACE_MAPPINGS here when the
      # dual-CAN (pican2Duo) topology is configured.
      settings = { };
    };

    # Pin the reserved uid/gid so /var/lib/coachiq ownership is stable across
    # rebuilds and DR restores. The upstream module creates the user/group but
    # does not assign a fixed id.
    users.users.coachiq.uid = mylib.serviceUids.coachiq.uid;
    users.groups.coachiq.gid = mylib.serviceUids.coachiq.gid;

    # CoachIQ's CAN recorder currently creates a relative ./recordings
    # directory. Run the service from its writable data directory so that
    # recorder state lands on the SSD-backed @coachiq subvolume.
    systemd.services.coachiq.serviceConfig.WorkingDirectory = "/var/lib/coachiq";

    # Production security secret. COACHIQ_ENVIRONMENT=production is hardcoded by
    # the module, so a real COACHIQ_SECURITY__SECRET_KEY is mandatory (the
    # coachiq-validate-config ExecStartPre fails otherwise).
    #
    # The decrypted secret is a systemd EnvironmentFile. Populate it with a
    # single line, e.g.:
    #   COACHIQ_SECURITY__SECRET_KEY=<openssl rand -hex 32>
    # Add it with: sops hosts/nixpi/secrets.sops.yaml   (key: coachiq_environment)
    sops.secrets.coachiq_environment = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "coachiq.service" ];
    };
  };
}
