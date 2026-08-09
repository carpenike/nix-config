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
# The MCP tools live in homelab-mcp (tools/amazon.py), NOT here. It reads this
# database through the `homelab-mcp` role declared below, which holds
# `readonly` membership — SELECT and nothing else. The `costco_*` tools are
# not written yet; when they are, they need no new grant, because the reader
# inherits SELECT on new tables via ALTER DEFAULT PRIVILEGES on the owner role.
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
# AND `costco_*` OUT of the `hermes` entry in HOMELAB_MCP_RESTRICTED_SCOPES,
# for the same reason `school_*` is kept out. Warehouse receipts are if
# anything worse: an itemised grocery run is a week of the household's life.
#
# That entry is an ALLOWLIST and fails closed, so a new tool category is
# excluded by default and this is a note about not adding it — not a step.
#
# MULTI-ACCOUNT. Every row carries an `account` label. A second Amazon account
# (e.g. Steffi's) is a SECOND lading-sync unit with its own sops
# EnvironmentFile, its own LADING_ACCOUNT slug and its own StateDirectory,
# writing to this same database — never a second credential in one env file.
# That keeps a compromised env file worth exactly one account.
#
# FLAKE LOCK: Renovate watches homelab-mcp and auto-merges its bumps within
# minutes; nothing watches carpenike/lading. So after pushing lading you MUST
# bump its input here by hand — on 2026-08-04 that was missed, and the deployed
# closure ran ahead of the committed lock, meaning the next apply from a clean
# checkout would have silently rolled a fix back with no diff to explain it.
# When in doubt, check the deployed closure rather than the lock:
#   grep -c <symbol> /nix/store/*-lading-*/lib/python*/site-packages/lading/...
# Adding lading to Renovate's watch list would remove the whole class of bug.
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
#            costco_tokens:         <the JSON blob captured from a browser>
#            samsclub_tokens:       <the JSON blob captured from a PHONE>
#
#      costco_tokens is a different KIND of secret from the three above it: a
#      SEED, not a standing credential. Azure B2C rotates the refresh token on
#      every use, so the live value lives in the unit's StateDirectory and this
#      one is installed only when no live token exists. Re-seed roughly twice a
#      year (the token is good for 90 days); see the upstream AGENTS.md for the
#      DevTools snippet that captures it.
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
    ryan = {
      environmentFile = config.sops.templates."lading-sync-ryan-env".path;

      # Costco warehouse receipts, on this same unit and this same timer.
      #
      # A SECOND SOURCE WITH A SECOND CREDENTIAL, and the two are decoupled in
      # both directions upstream: the Costco fetch performs no amazon.com
      # login, so an Amazon account being challenged does not stop warehouse
      # receipts arriving, and vice versa. It shares the unit only because it
      # shares the account label and the state directory.
      #
      # Only ryan's membership exists, so this is deliberately NOT mirrored
      # onto steffi below — unlike the Amazon keys, where the symmetry is the
      # point. The upstream module derives LADING_COSTCO_ACCOUNTS for the
      # health unit from whichever accounts set this, so /healthz cannot end
      # up disagreeing with which units actually sync Costco.
      costco = {
        enable = true;
        tokenSeedFile = config.sops.secrets."lading/ryan/costco_tokens".path;
      };

      # Sam's Club in-club receipts. A THIRD SOURCE with a third credential,
      # decoupled from both others in the same way Costco is.
      #
      # Only ryan's membership is seeded, so this is deliberately NOT mirrored
      # onto steffi below — the same asymmetry the Costco block started with,
      # and for the same reason: a second membership needs its own token, and
      # capturing one here is not a browser snippet. The samsclub.com WEB API
      # returns no totals, no line prices and no machine-readable date for this
      # cohort; only the mobile app's API does. So seeding an account means
      # putting THAT PERSON'S PHONE behind a proxy with a CA installed.
      #
      # Worth doing once for steffi eventually — Costco's numbers say so
      # loudly: one membership matched 40.5% of charges, two matched 90.5% —
      # but it needs her, not just her credentials.
      samsclub = {
        enable = true;
        tokenSeedFile = config.sops.secrets."lading/ryan/samsclub_tokens".path;
      };
    };

    steffi = {
      environmentFile = config.sops.templates."lading-sync-steffi-env".path;
      # A different hour: two logins to two Amazon accounts from one IP
      # inside the same minute is a more interesting pattern than two
      # spread across the night.
      onCalendar = [ "*-*-* 05:40:00" ];

      # A SECOND COSTCO MEMBERSHIP, and the reason this is not optional.
      #
      # Measured 2026-08-07 against the real ledger: with only ryan's
      # membership synced, 17 of 42 Costco charges (40.5%) had a receipt —
      # and every one of those 17 matched exactly, so the matcher was never
      # wrong, it was blind. A 15-month query on ryan's account returns ONE
      # distinct membershipNumber, and matched and unmatched trips alternate
      # week by week for fifteen months. Two people, two cards.
      #
      # Costco's warehouse receipts attach to the membership number scanned at
      # the register, not to the household, so the other card's trips live in
      # its own online account and ryan's will never show them. This is the
      # same shape as the second Amazon account, and the same fix.
      costco = {
        enable = true;
        tokenSeedFile = config.sops.secrets."lading/steffi/costco_tokens".path;
      };
    };
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
          # Costco's rolling window. Wider than Amazon's 45 because the fetch
          # is ONE cheap GraphQL call with no per-record follow-up, so the
          # overlap costs almost nothing and heals a longer outage. Costco
          # only exposes about two years of history, which bounds any backfill.
          costco_window_days = 90;
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
        #
        # NOT the plain `homelab-mcp` role, which schoolhouse.nix already
        # declares. A Postgres role is CLUSTER-wide and has ONE password, so
        # two databases each provisioning `homelab-mcp` against a different
        # sops secret makes the password flap with provisioning order —
        # whichever ran last wins and the other DSN starts failing
        # authentication. That is exactly what happened on the first deploy
        # here: schoolhouse won, and every amazon_* call returned
        # `lading_unreachable` while nothing complained at startup, because
        # registration only checks that a DSN string is set.
        #
        # A distinct role per store removes that ordering dependency. It does
        # NOT buy isolation between the stores, and it was verified rather
        # than assumed: `readonly` is itself a cluster-wide group carrying
        # SELECT grants in every provisioned database, so this role can read
        # schoolhouse too. That is not an escalation — homelab-mcp already
        # holds both DSNs — but do not describe it as a boundary.
        additionalRoles."homelab-mcp-lading" = {
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
