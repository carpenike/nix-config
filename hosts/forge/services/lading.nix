# lading — Amazon order + transaction ingest for the household ledger.
# Upstream: https://github.com/carpenike/lading  (PRIVATE)
#
# Two units from one package, sharing a Postgres schema and nothing else:
#
#   lading-sync.service   oneshot, once daily with an hour of jitter. Holds
#                         the Amazon credentials and does the fragile work
#                         (login, scrape, parse).
#   lading.service        health endpoint. Serves exactly one route,
#                         /healthz, so Gatus can alert on a sync that
#                         quietly stopped.
#
# Forge owns PostgreSQL provisioning, secrets, monitoring and backups; the
# upstream flake owns the package and the hardened units.
#
# The MCP tools live in homelab-mcp (tools/amazon.py, not yet written), NOT
# here. It reads this database through the `homelab-mcp` role declared below,
# which holds `readonly` membership — SELECT and nothing else.
#
# EXPOSURE — read this before enabling. The sync unit holds an Amazon
# username, password and TOTP seed. That credential CAN PLACE ORDERS AND
# CHANGE SHIPPING ADDRESSES; there is no read-only Amazon account and no
# scoped token, because the library authenticates as the human. Three
# controls, all of them structural rather than conventional:
#
#   1. It lives in its OWN unit with no inbound socket, not in homelab-mcp,
#      which is a network-facing OAuth resource server.
#   2. Its EnvironmentFile is separate from the health unit's, so the
#      always-on process holds no credential at all.
#   3. There is no retry loop in the process — a failed login exits non-zero
#      and systemd backs off (RestartSec=300, StartLimitBurst=2), because a
#      tight retry against Amazon is how an account gets challenge-locked.
#
# Purchase history is also more sensitive than it looks: it leaks gifts before
# they are given, medical supplies, and anything anyone bought. Keep `amazon_*`
# OUT of the `hermes` entry in HOMELAB_MCP_RESTRICTED_SCOPES when those tools
# land, for the same reason `school_*` is kept out.
#
# MULTI-ACCOUNT. Every row carries an `account` label. A second Amazon account
# (e.g. Steffi's) is a SECOND lading-sync unit with its own sops
# EnvironmentFile, its own LADING_ACCOUNT slug and its own StateDirectory,
# writing to this same database — never a second credential in one env file.
# That keeps a compromised env file worth exactly one account.
#
# One-time setup:
#   1. Add `carpenike/lading` to the fine-grained GitHub PAT behind the
#      `nix/access-tokens` SOPS secret, or the flake input 404s at build time.
#   2. Add the `lading` values documented in hosts/forge/secrets.nix to
#      hosts/forge/secrets.sops.yaml.
#   3. Run `task nix:apply-nixos host=forge`. The sync unit runs migrations
#      via ExecStartPre.
#   4. Verify the service can log in on its OWN:
#        systemctl start lading-sync.service
#        journalctl -u lading-sync -n 50
#      An "amazon session authenticated" line means the login path works. An
#      AmazonOrdersAuthError usually means the TOTP seed — Amazon displays it
#      in space-separated groups and it must be valid base32 (upstream
#      normalises spaces, quotes and hyphens, and validates at startup).
#   5. Load existing history rather than re-scraping: see the transfer script
#      in the upstream repo (scripts/export-for-forge.sh).

{ config, inputs, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "lading";
  listenAddr = "127.0.0.1";
  # 9200 is homelab-mcp, 9210 its Actual sidecar, 9220 schoolhouse. Next in
  # that family; the first schoolhouse deploy failed with EADDRINUSE for
  # exactly this reason.
  listenPort = 9230;

  serviceEnabled = config.services.lading.enable or false;
in
{
  imports = [
    inputs.lading.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.lading = {
        enable = true;
        package = inputs.lading.packages.${pkgs.stdenv.hostPlatform.system}.default;

        bindAddress = listenAddr;
        port = listenPort;

        # Non-secret settings (visible in /nix/store). The account LABEL is
        # not secret — it is a slug like "ryan", carrying no credential — but
        # the username, password and TOTP seed all live in the sops env file.
        settings = {
          # Whose Amazon account this unit syncs. Stamped on every row it
          # writes, and read by the health unit so a freshly deployed account
          # reports "starting" rather than being absent from /healthz.
          # Adding Steffi's account means a second unit with account =
          # "steffi" and its own EnvironmentFile — not a second credential
          # in this one.
          account = "ryan";
          # Storage is UTC; this is the rendering zone for MCP answers.
          timezone = "America/New_York";
          # /healthz flips to 503 past this, which is what Gatus alerts on.
          # The sync is daily, so 36h tolerates one missed run; two missed
          # runs is a real outage and should page.
          stale_after_hours = 36;
          # Rolling transaction window. Overlaps the daily cadence on purpose
          # so a missed run heals on the next one rather than leaving a hole
          # only a manual backfill can fill.
          transaction_window_days = 45;
          # Per-order detail pages cost one extra request each and are fetched
          # once per order, ever. This bounds what an UNATTENDED run can fire
          # after a backfill; it is a precaution, not a measured rate limit.
          max_detail_fetches_per_run = 40;
        };

        environmentFile = config.sops.templates."lading-health-env".path;
        sync.environmentFile = config.sops.templates."lading-sync-env".path;
      };

      modules.services.postgresql.databases.${serviceName} = {
        owner = serviceName;
        ownerPasswordFile = config.sops.secrets."lading/db_password".path;
        permissionsPolicy = "owner-readwrite+readonly-select";

        # The reader homelab-mcp connects as for the amazon_* tools.
        # Membership in `readonly` means CONNECT + USAGE + SELECT: the
        # always-on process that controls the house is physically incapable of
        # rewriting purchase history, which is a stronger guarantee than "the
        # read path contains no INSERT".
        additionalRoles."homelab-mcp" = {
          passwordFile = config.sops.secrets."lading/reader_password".path;
          grantRoles = [ "readonly" ];
        };
      };

      # Both units must wait for forge's declarative provisioning, not just
      # for postgresql itself — the role and database have to exist before the
      # first migration connects.
      systemd.services.lading-sync = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };

      systemd.services.lading = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # The health endpoint being down is a nuisance; the SYNC being broken is
      # the failure that matters, and it is silent by construction — a scraper
      # that stopped working looks exactly like a quiet month of not buying
      # anything, and the advisor would go on reporting "no Amazon order
      # behind that charge" with total confidence. /healthz carries that
      # signal (503 once the last successful sync per account/source is older
      # than stale_after_hours), so probe it rather than the process.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Lading";
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
          # ~25 minutes of failures before paging. Staleness is measured in
          # DAYS here, so this threshold is really about the endpoint being
          # unreachable; a late sync is already absorbed by stale_after_hours.
          failureThreshold = 5;
          successThreshold = 1;
        }];
      };

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Lading"
          "Amazon ingest health probe";

      # Deliberately NOT contributed to homepage: the dashboard is shared, and
      # a tile linking to the household's purchase history does not belong on
      # it. There is also nothing to link to — this unit serves only /healthz.
    })
  ];
}
