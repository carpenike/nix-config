# lading — Amazon order + transaction ingest for the household ledger.
# Upstream: https://github.com/carpenike/lading  (PRIVATE)
#
# Two units from one package, sharing a Postgres schema and nothing else:
#
#   lading-sync-<account>.service
#                         oneshot, once daily with an hour of jitter. Holds
#                         that account's Amazon credentials and does the
#                         fragile work (login, scrape, parse). One per account.
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
#      hosts/forge/secrets.sops.yaml:
#
#        lading:
#          db_password:     <openssl rand -hex 32>   # URL-safe: goes in a DSN
#          reader_password: <openssl rand -hex 32>   # ditto
#          ryan:
#            amazon_username:       <email>
#            amazon_password:       <password>
#            amazon_otp_secret_key: <base32 seed, spaces and all>
#
#      db_password and reader_password are shared — one database, one
#      readonly role. Everything under an account name belongs to exactly
#      that Amazon login, so a second account adds a sibling block rather
#      than a differently-named set of keys.
#   3. Run `task nix:apply-nixos host=forge`.
#
#      What starts at activation: `lading.service` only. It runs
#      lading-migrate via ExecStartPre, so the schema exists immediately.
#      `lading-sync-ryan.service` is oneshot with no wantedBy — it does NOT
#      run on apply. Its TIMER starts, and fires at 04:20 plus up to an hour
#      of jitter.
#
#   4. IF SEEDING FROM AN EXISTING STORE, do it before that timer fires.
#      scripts/export-for-forge.sh refuses to load into a non-empty store,
#      because the dump carries its source's primary-key ids and merging
#      them would either collide or silently drop rows. So:
#
#        systemctl stop lading-sync-ryan.timer
#        # copy lading-export.sql across, then from the upstream checkout:
#        ./scripts/export-for-forge.sh load \
#          "postgresql://lading:PASSWORD@127.0.0.1:5432/lading"
#        systemctl start lading-sync-ryan.timer
#
#      Stopping the timer first is REQUIRED, not caution. Observed on the
#      2026-08-04 deploy: a fresh Persistent=true timer fired its service
#      immediately at activation (17:21:00, seconds after the switch), so the
#      seeding window is otherwise zero. The documented "writes a stamp file
#      instead of firing" behaviour did not apply here.
#
#   5. Verify the service can log in on its OWN:
#        systemctl start lading-sync-ryan.service
#        journalctl -u lading-sync-ryan -n 50
#      An "amazon session authenticated" line means the login path works. An
#      AmazonOrdersAuthError usually means the TOTP seed — Amazon displays it
#      in space-separated groups and it must be valid base32 (upstream
#      normalises spaces, quotes and hyphens, and validates at startup).
#
#      /healthz reads "starting" (503) until this first run succeeds, even
#      when seeded: ingest_runs is deliberately not transferred, so the host
#      reports its OWN sync freshness rather than inheriting a laptop's.
#
#      IF THAT RUN HITS A JAVASCRIPT CHALLENGE (it did on 2026-08-04), the
#      unblock is to copy a working cookie jar from a host that has one:
#
#        install -o lading -g lading -m 0600 amazon.cookies.json \
#          /var/lib/lading/<account>/amazon.cookies.json
#
#      That jar IS a live authenticated session — treat it as the password.
#      It works by skipping the login flow, which is the part being
#      challenged. Do NOT respond by packaging Playwright or a captcha
#      solver; see "Field notes" in the upstream repo's AGENTS.md for what
#      is and is not known about that challenge.

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

  # One entry per Amazon account. Declared here rather than inline so the
  # ordering dependencies below are derived from the SAME list — a
  # hand-maintained second copy is how `lading-sync` ended up ordered after
  # postgres while the unit that actually runs, `lading-sync-ryan`, was not.
  syncAccounts = {
    ryan.environmentFile = config.sops.templates."lading-sync-ryan-env".path;

    # steffi = {
    #   environmentFile = config.sops.templates."lading-sync-steffi-env".path;
    #   # A different hour: two logins to two Amazon accounts from one IP
    #   # inside the same minute is a more interesting pattern than two
    #   # spread across the night.
    #   onCalendar = [ "*-*-* 05:40:00" ];
    # };
  };

  # The role and database must exist before the first migration connects, so
  # both kinds of unit wait on forge's declarative provisioning rather than on
  # postgresql.service alone.
  waitForProvisioning = {
    after = [ "postgresql-provision-databases.service" ];
    requires = [ "postgresql-provision-databases.service" ];
  };
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
          # NOTE: LADING_ACCOUNT and LADING_STATE_DIR are set PER UNIT by the
          # upstream module from `sync.accounts` below — do not put them here,
          # or every account would share one label and one cookie jar.
          #
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

        # One unit per Amazon account (see `syncAccounts` above). Adding
        # Steffi's is: a new key set in secrets.nix, a new sops template, and
        # a new entry there — never a second credential in an existing file.
        # The module derives the unit name, the LADING_ACCOUNT label, the
        # StateDirectory (its own cookie jar, which is a live session and must
        # not be shared) and the timer.
        sync.accounts = syncAccounts;
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

      # Applied to the health unit and to every generated per-account sync
      # unit. Derived from `syncAccounts`, so adding an account cannot leave
      # its unit racing the database.
      systemd.services = { lading = waitForProvisioning; }
        // lib.mapAttrs' (name: _: lib.nameValuePair "lading-sync-${name}" waitForProvisioning)
        syncAccounts;
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
