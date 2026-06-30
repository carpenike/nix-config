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
{ config
, inputs
, mylib
, ...
}:
{
  imports = [
    inputs.coachiq.nixosModules.default
  ];

  config = {
    services.coachiq = {
      enable = true;

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

    # The decrypted secret is a systemd EnvironmentFile, keeping secrets out of
    # Nix options, the store, and systemd Environment=. Populate it with a
    # single line when a production security secret is needed, e.g.:
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
