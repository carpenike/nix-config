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

      # Bind to loopback; Caddy on the same host fronts coachiq and the
      # Cloudflare tunnel terminates public TLS. openFirewall stays off — the
      # only ingress is the tunnel -> Caddy -> loopback path.
      host = "127.0.0.1";
      port = 8000;
      dataDir = "/var/lib/coachiq";
      logLevel = "INFO";

      # Caddy (and the Cloudflare edge) terminate TLS; tell uvicorn to trust
      # X-Forwarded-* so redirects/cookies use https://iq.holtel.io.
      tlsTerminationIsExternal = true;
      openFirewall = false;

      # Root-readable EnvironmentFile carrying the secrets that must NOT live in
      # the Nix store: COACHIQ_SECURITY__SECRET_KEY (session), COACHIQ_AUTH__SECRET_KEY
      # (JWT), and COACHIQ_AUTH__OIDC_CLIENT_SECRET (PocketID). Add them with
      #   sops hosts/nixpi/secrets.sops.yaml    (key: coachiq_environment)
      environmentFile = config.sops.secrets.coachiq_environment.path;

      # Non-secret COACHIQ_* settings (full env var names; secrets go in the
      # EnvironmentFile above). Enforce auth and native PocketID OIDC.
      settings = {
        # Turn on authentication + native OIDC against the home PocketID server.
        COACHIQ_AUTH__ENABLED = true;
        COACHIQ_AUTH__OIDC_ENABLED = true;
        COACHIQ_AUTH__OIDC_ISSUER = "https://id.holthome.net";
        COACHIQ_AUTH__OIDC_CLIENT_ID = "coachiq";

        # Required by upstream when OIDC is enabled: absolute external origin
        # (scheme+host only, no path, no trailing slash). Drives OIDC redirect
        # URIs and cookie/redirect generation.
        COACHIQ_SERVER__PUBLIC_ORIGIN = "https://iq.holtel.io";
      };
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

    # Caddy vhost — pure pass-through (no caddySecurity). coachiq enforces its
    # own native PocketID OIDC; Caddy just terminates TLS for the tunnel origin
    # and proxies to loopback. Opting the hostname into the "nixpi" tunnel makes
    # the cloudflared module auto-discover it for ingress + DNS registration.
    modules.services.caddy.virtualHosts.coachiq = {
      enable = true;
      hostName = "iq.holtel.io";
      backend = {
        host = "127.0.0.1";
        port = 8000;
      };
      cloudflare = {
        enable = true;
        tunnel = "nixpi";
      };
    };
  };
}
