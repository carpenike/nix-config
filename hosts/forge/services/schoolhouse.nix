# schoolhouse — Schoology parent-account ingest + store (+ a health probe).
# Upstream: https://github.com/carpenike/schoolhouse
#
# Two units from one package, sharing a Postgres schema and nothing else:
#
#   schoolhouse-ingest.service   oneshot, twice daily on weekdays. Holds the
#                                Schoology credentials and does the fragile
#                                work (login, fetch, parse).
#   schoolhouse.service          health endpoint. Serves exactly one route,
#                                /healthz, so Gatus can alert on a sync that
#                                quietly stopped.
#
# Forge owns PostgreSQL provisioning, secrets, monitoring and backups; the
# upstream flake owns the package and the hardened units.
#
# The MCP tools live in homelab-mcp (tools/school.py), NOT here. It already
# runs a spec-clean OAuth 2.1 AS federated to PocketID with a user allowlist
# and per-scope server-side tool allowlists, so a second authorization server
# here would have been duplicated auth code guarding the more sensitive data.
# It reads this database through the `homelab-mcp` role declared below, which
# holds `readonly` membership — SELECT and nothing else.
#
# EXPOSURE. Three minors' education records. Two controls, both in
# homelab-mcp: the OAuth user allowlist (the two parents), and keeping
# `school_*` OUT of the `hermes` entry in HOMELAB_MCP_RESTRICTED_SCOPES so the
# ambient household agent cannot read them. This unit itself stays
# loopback-only and serves no tools at all.
#
# One-time setup:
#   1. Add the `schoolhouse` values documented in hosts/forge/secrets.nix to
#      hosts/forge/secrets.sops.yaml.
#   2. Apply forge. The ingest unit runs migrations via ExecStartPre.
#   3. Verify the service can log in on its OWN (every dev run so far reused
#      a browser-captured cookie jar):
#        systemctl start schoolhouse-ingest.service
#        journalctl -u schoolhouse-ingest -n 50
#      A "logged in to https://app.schoology.com" line means the form POST
#      path works. A LoginFailedError means the captured form shape drifted —
#      re-run the upstream recon capture.

{ config, inputs, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "schoolhouse";
  listenAddr = "127.0.0.1";
  listenPort = 9210;

  serviceEnabled = config.services.schoolhouse.enable or false;
in
{
  imports = [
    inputs.schoolhouse.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.schoolhouse = {
        enable = true;
        package = inputs.schoolhouse.packages.${pkgs.stdenv.hostPlatform.system}.default;

        bindAddress = listenAddr;
        port = listenPort;

        # Non-secret settings (visible in /nix/store). Child ids, iCal feed
        # URLs and every credential live in the sops env files below — the
        # ids identify minors and the feed URLs are capability URLs.
        settings = {
          # Parents use a native Schoology account at app.schoology.com.
          # lms.fcps.org is the STUDENT door and redirects into ADFS +
          # Microsoft Entra; pointing this there lands in the wrong auth
          # system entirely.
          schoology_origin = "https://app.schoology.com";
          # Storage is UTC; this is the rendering zone for MCP answers, so
          # "due Thursday" means Thursday here rather than 7:59pm UTC.
          timezone = "America/New_York";
          # /healthz flips to 503 past this, which is what Gatus alerts on.
          stale_after_hours = 18;
          # ~10 MB of gzipped HTML per run at 2 runs/day. The archive is what
          # makes a broken parser fixable after the fact rather than a data
          # loss event, so this is deliberately generous.
          raw_retention_days = 30;
          faculty_refresh_days = 7;
        };

        environmentFile = config.sops.templates."schoolhouse-health-env".path;
        ingest.environmentFile = config.sops.templates."schoolhouse-ingest-env".path;
      };

      modules.services.postgresql.databases.${serviceName} = {
        owner = serviceName;
        ownerPasswordFile = config.sops.secrets."schoolhouse/db_password".path;
        permissionsPolicy = "owner-readwrite+readonly-select";

        # The reader homelab-mcp connects as for the school_* tools. Membership
        # in `readonly` means CONNECT + USAGE + SELECT: the always-on process
        # that controls the house is physically incapable of writing a child's
        # grade history, which is a stronger guarantee than "the read path
        # contains no INSERT".
        additionalRoles."homelab-mcp" = {
          passwordFile = config.sops.secrets."schoolhouse/reader_password".path;
          grantRoles = [ "readonly" ];
        };
      };

      # Both units must wait for forge's declarative provisioning, not just
      # for postgresql itself — the role and database have to exist before
      # the first migration connects.
      systemd.services.schoolhouse-ingest = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };

      systemd.services.schoolhouse = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # The MCP server being down is a nuisance; the INGEST being broken is
      # the failure that matters, and it is silent by construction — a
      # scraper that stopped working looks exactly like a quiet week at
      # school. /healthz carries that signal (503 once the last successful
      # ingest is older than stale_after_hours), so probe it rather than the
      # process.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Schoolhouse";
        group = "applications";
        url = "http://${listenAddr}:${toString listenPort}/healthz";
        interval = "300s";
        conditions = [
          "[STATUS] == 200"
          "[BODY].status == ok"
          "[RESPONSE_TIME] < 5000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          # ~25 minutes of failures before paging. The ingest schedule has
          # 15 minutes of jitter, so a tighter threshold would page on a
          # perfectly healthy late run.
          failureThreshold = 5;
          successThreshold = 1;
        }];
      };

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Schoolhouse"
          "Schoology ingest health probe";

      # Deliberately NOT contributed to homepage: the dashboard is shared,
      # and a tile linking to three children's grades does not belong on it.
      # There is also nothing to link to — this unit serves only /healthz.
    })
  ];
}
