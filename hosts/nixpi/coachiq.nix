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

      # RouterOS sidecar (HOF-073): a dedicated tokenless plain-HTTP listener on
      # 0.0.0.0:8100, separate from the authed main API, that the RV MikroTik
      # router polls for /location-state + /starlink/verdict. The firewall opens
      # 8100 ONLY on end0 (the RV LAN NIC holding 192.168.88.30) — never the
      # Cloudflare tunnel / WAN (a module assertion enforces lanInterfaces here).
      # Home lat/lon drive the home/away verdict and reveal the RV's home
      # address, so they go in the sops EnvironmentFile as
      # COACHIQ_ROUTER_SIDECAR__HOME_LATITUDE / __HOME_LONGITUDE, NOT in settings
      # (this repo is public). Without them /location-state safely returns "unknown".
      routerSidecar = {
        enable = true;
        openFirewall = true;
        lanInterfaces = [ "end0" ];
      };

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

        # Base URL for magic-link generation. The production security validator
        # hard-fails startup ("base_url is required when magic links are enabled")
        # because magic links default on. We authenticate via OIDC, but set this
        # to the public origin to satisfy the validator (magic links are inert
        # without SMTP). Alternatively set COACHIQ_AUTH__ENABLE_MAGIC_LINKS = false.
        COACHIQ_AUTH__BASE_URL = "https://iq.holtel.io";

        # Select the coach mapping for our RV (2021 Entegra Aspire 44R). Value is
        # the bundled config/<model>.yml filename without the extension; without
        # it coachiq falls back to the generic coach_mapping.default.yml (1 entity).
        COACHIQ_RVC__COACH_MODEL = "2021_Entegra_Aspire_44R";

        # Attach BOTH CAN ports and map them to the buses they actually carry.
        # Without these, coachiq defaults to can0 only with house=can0 — and the
        # physical wiring is the other way around. Verified 2026-07-04 via
        # candump on nixpi: can1 carries RV-C house traffic (DGN 1FEDA
        # DC_DIMMER_STATUS_3 etc., ~133 f/s from the Firefly system) while can0
        # carries J1939 chassis traffic (18FECA DM1 diagnostics, quiet with
        # engine off). The app was listening to the near-silent chassis port.
        COACHIQ_CAN__INTERFACES = "can0,can1";
        COACHIQ_CAN__INTERFACE_MAPPINGS = builtins.toJSON {
          house = "can1";
          chassis = "can0";
        };

        # Victron Cerbo GX power-system integration (coachiq PR #200): pulls
        # inverter/charger, EG4 battery, solar, and system telemetry from the
        # Cerbo's local MQTT broker (dbus-flashmq, port 1883) and exposes
        # admin-gated VE.Bus mode / input-current-limit control. The broker is
        # unauthenticated on the RV LAN, so no secrets are involved. Requires
        # MQTT enabled on the Cerbo (Settings -> Services -> MQTT, done 2026-07-05).
        COACHIQ_VICTRON__ENABLED = true;
        COACHIQ_VICTRON__HOST = "cerbo.holtel.io";
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
