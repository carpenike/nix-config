# hosts/forge/services/marginalia.nix
#
# Marginalia — a cook log service ("lab notebook for cooking") on forge.
# Upstream: https://github.com/carpenike/marginalia
#
# Deploy-pattern twin of Whiskey (services/whiskeywhiskeywhiskey.nix):
# Node + TypeScript + Fastify + SQLite + MCP served from one Node process,
# bound to localhost behind Caddy + Cloudflare Tunnel, run under a hardened
# systemd DynamicUser with its SQLite DB in the StateDirectory.
#
# Architecture:
#   browser  ─┐
#             ├─► Cloudflare Tunnel (forge) ──► Caddy ──► Fastify (127.0.0.1:3418)
#   claude   ─┘                                                 │
#                                                               ▼
#                                              /var/lib/marginalia/marginalia.sqlite
#
# Notes:
#   * The upstream module uses `DynamicUser` + `StateDirectory`. systemd will
#     chown the ZFS mountpoint to the ephemeral UID on every service start, so
#     the dataset is configured with `root:root 0700` and we let systemd take
#     over. No entry in `lib/service-uids.nix` is required. (Same model as
#     Whiskey — see that module for the full rationale.)
#   * The app handles OIDC natively against PocketID — a NEW client distinct
#     from Whiskey's. We deliberately skip `caddySecurity` on the vhost; Caddy
#     is a pure pass-through so the app's own OIDC + embedded OAuth AS can run
#     the MCP custom-connector flow unimpeded.
#   * Marginalia has NO dependency on Whiskey (upstream principle 2). It reads
#     CookLang lineage one-way; `COOKLANG_BASE_URL` below is metadata-only and
#     makes zero outbound calls unless lineage stitching is requested.
#   * In PRODUCTION the upstream service refuses to start unless all six auth
#     keys are present: the four non-secret `MARGINALIA_*` settings here plus
#     the two secrets (`MARGINALIA_OIDC_CLIENT_SECRET`,
#     `MARGINALIA_SESSION_SECRET`) assembled into the SOPS env template.
#
# Pre-flight (one-time setup before the first apply succeeds):
#   1. In PocketID admin → OIDC Clients → Add a NEW client (distinct from
#      Whiskey's):
#        Client ID:    marginalia
#        Client Secret: <generate; copy into secrets.sops.yaml below>
#        Callback URLs: https://marginalia.holthome.net/api/auth/callback  (SPA)
#                       https://marginalia.holthome.net/oauth/callback      (AS)
#        Scopes:        openid email profile
#   2. Encrypt the following keys via `sops hosts/forge/secrets.sops.yaml`:
#        marginalia:
#          oidc_client_secret: <from PocketID admin>
#          session_secret:     <openssl rand -hex 48>   # signs the session cookie
#   3. Run `task nix:apply-nixos host=forge` to bring the service up.
#
# NOTE: the upstream repo is private. forge fetches it via the GitHub PAT in
# the `nix/access-tokens` SOPS secret (already wired for Whiskey). Add
# `carpenike/marginalia` to that fine-grained token's repository access or the
# build will 404 on the flake input.

{ config, lib, inputs, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "marginalia";
  serviceDomain = "marginalia.${config.networking.domain}";
  pocketIdIssuer = "https://id.${config.networking.domain}";

  listenAddr = "127.0.0.1";
  # Whiskey runs on 3417 on this same box — give Marginalia a distinct port,
  # as the upstream module example calls out.
  listenPort = 3418;

  # systemd StateDirectory name; the upstream module hard-codes
  # `StateDirectory = "marginalia"`, which yields this path.
  stateDirName = "marginalia";
  dataDir = "/var/lib/${stateDirName}";
  dataset = "tank/services/${serviceName}";

  serviceEnabled = config.services.marginalia.enable or false;
in
{
  imports = [
    inputs.marginalia.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.marginalia = {
        enable = true;
        package = inputs.marginalia.packages.${pkgs.stdenv.hostPlatform.system}.default;

        host = listenAddr;
        port = listenPort;
        dataDir = dataDir;
        logLevel = "info";

        # Non-secret auth + lineage configuration. Visible in the Nix store.
        # In production all four MARGINALIA_* auth keys are REQUIRED (the
        # service's boot guard refuses to start without them + the two
        # secrets in the env template below).
        settings = {
          MARGINALIA_PUBLIC_BASE_URL = "https://${serviceDomain}";
          MARGINALIA_OIDC_ISSUER = pocketIdIssuer;
          MARGINALIA_OIDC_CLIENT_ID = "marginalia";
          MARGINALIA_OIDC_REDIRECT_URI = "https://${serviceDomain}/api/auth/callback";

          # CookLang lineage stitching (HOF-004, optional). Enables
          # `derived_from` lineage / the get_lineage tool. Metadata-only —
          # Marginalia stores recipe slugs, never recipe content (principle
          # 1), and makes zero outbound calls unless lineage is requested.
          # Points at the household-public cook server (see cooklang.nix).
          COOKLANG_BASE_URL = "https://cook.${config.networking.domain}";
        };

        # Secrets are merged in via SOPS template (see hosts/forge/secrets.nix).
        # File is root-readable only; systemd reads it before dropping to the
        # DynamicUser.
        environmentFile = config.sops.templates."marginalia-env".path;

        # Default off — Caddy on the same host fronts the service.
        openFirewall = false;
      };

      # Refuse to start the service if the ZFS dataset isn't mounted.
      # Without this, on a fresh deploy systemd's DynamicUser will happily
      # write the SQLite DB to the rpool fallback path; the dataset gets
      # mounted on top later and silently hides the data. (We hit exactly
      # this class of bug with Whiskey on 2026-05-13 → 2026-05-14.)
      # RequiresMountsFor pulls in the matching .mount unit and waits for it
      # before ExecStart.
      systemd.services.marginalia.unitConfig.RequiresMountsFor = [
        dataDir
      ];

      # Same guard for the upstream maintenance oneshot template
      # (`marginalia-maintenance@.service`). It shares the main service's
      # DynamicUser identity + StateDirectory and writes to the same SQLite
      # DB, so a migrate/seed run before the ZFS dataset is mounted would hit
      # the identical fallback-path data-loss bug.
      systemd.services."marginalia-maintenance@".unitConfig.RequiresMountsFor = [
        dataDir
      ];

      # Same guard for the upstream auto-migrate oneshot
      # (`marginalia-migrate.service`, added upstream dec7e6af). It runs
      # Before marginalia.service on every activation, shares the same
      # DynamicUser + StateDirectory, and writes the SQLite DB — so on a
      # fresh deploy it could migrate onto the rpool fallback path before the
      # ZFS dataset mounts. Guard it like the other two units.
      systemd.services.marginalia-migrate.unitConfig.RequiresMountsFor = [
        dataDir
      ];

      # Caddy vhost — canonical hostname. Pure pass-through; the app does OIDC
      # against PocketID itself (plus an embedded OAuth AS for the MCP
      # connector flow), so no caddySecurity here.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = listenAddr;
          port = listenPort;
        };
        # Cloudflare Tunnel auto-registers marginalia.holthome.net via the
        # existing forge tunnel + DNS API token. No manual dashboard step.
        cloudflare = {
          enable = true;
          tunnel = "forge";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for the SQLite state directory.
      # owner=root is intentional: the upstream module uses systemd
      # DynamicUser + StateDirectory, so the runtime UID is ephemeral and
      # assigned by systemd at service start. systemd bind-mounts
      # /var/lib/private/marginalia into place and chowns *that* path to the
      # DynamicUser. The ZFS mountpoint at /var/lib/marginalia only needs to
      # exist and be root-accessible for systemd to do the bind.
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = dataDir;
        recordsize = "16K"; # SQLite page-aligned writes
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "root";
        group = "root";
        mode = "0700";
        rootOwnedReason = "Upstream module uses systemd DynamicUser; systemd manages runtime ownership via StateDirectory bind mount.";
      };

      # ZFS snapshots + replication to nas-1 via the standard forge template.
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      # Restic backup. The upstream service uses DynamicUser so it doesn't
      # plug into the unified `modules.services.<name>.backup` auto-discovery
      # path — we register the job manually. `useSnapshots = true` gives us a
      # consistent SQLite snapshot at backup time.
      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ dataDir ];
        tags = [ serviceName "sqlite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      # Service-down alert (native systemd unit).
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "marginalia"
          "Marginalia"
          "Cook log service";

      # Gatus blackbox check from the public side. Lets us know if the full
      # Cloudflare → tunnel → Caddy → app path is healthy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Marginalia";
        group = "applications";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          # The app root is behind OIDC, so 200 or 302 are both healthy.
          "[STATUS] == any(200, 302)"
          "[RESPONSE_TIME] < 5000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };
    })
  ];
}
