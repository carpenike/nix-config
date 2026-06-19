# hosts/forge/services/grocy.nix
#
# Grocy — self-hosted groceries & household management (ERP for your fridge:
# stock, shopping lists, chores, tasks, recipes, meal planning) on forge.
# Upstream: https://github.com/grocy/grocy
#
# Why NATIVE (services.grocy) instead of a container:
#   Per .github/instructions/nixos-instructions.md the rule is "native when the
#   service is in nixpkgs" and "container only when not in nixpkgs / upstream
#   only ships containers / isolation critical". Grocy IS in nixpkgs and meets
#   none of the container criteria. The only container image (lscr.io/linuxserver
#   /grocy) is a root + s6 + PUID/PGID LinuxServer.io image — exactly the family
#   this repo has been migrating away from (we use rootless ghcr.io/home-operations
#   images). So native is the clearly-correct choice here.
#
# Architecture:
#   browser ─► Caddy (TLS + PocketID SSO) ──► grocy's own nginx (127.0.0.1)
#                                                   │ php_fastcgi (unix socket)
#                                                   ▼
#                                             phpfpm-grocy (Grocy PHP app)
#                                                   │
#                                                   ▼
#                                   /var/lib/grocy/grocy.db (SQLite) + storage/
#
#   The upstream services.grocy module hard-wires its own nginx vhost + PHP-FPM
#   pool (they are tightly coupled: the grocy user shares the nginx group and the
#   FPM socket). We don't fight that — instead we pin grocy's nginx to a loopback
#   port (no ACME) and let forge's Caddy remain the single TLS/auth edge.
#
# Auth model — per-user SSO via trusted header (ADR-008 Pattern 2):
#   We need real per-user identity inside Grocy so chores/tasks/stock changes
#   attribute to the right person (Ryan + spouse), so the shared-account pattern
#   (DISABLE_AUTH + gate) is NOT appropriate here. Instead:
#     1. Caddy enforces PocketID SSO (caddySecurity.home — requires the "home"
#        group) and, via caddy-security's `inject headers with claims`, injects
#        the authenticated identity as `X-Token-User-Email` into the upstream
#        request. (The "home" policy already exists in pocketid.nix and
#        injectHeaders defaults to true, so no shared-infra changes are needed.)
#     2. Grocy runs ReverseProxyAuthMiddleware and reads that header as the
#        username. Its middleware auto-creates the Grocy user on first login
#        (CreateUser with DEFAULT_PERMISSIONS), so no pre-seeding is required —
#        Ryan and his spouse each get their own account the first time they log
#        in. (See upstream middleware/ReverseProxyAuthMiddleware.php.)
#
#   Spoofing protection: grocy's nginx binds to 127.0.0.1 only, so the only path
#   to it is through Caddy, and caddy-security overwrites X-Token-* from the
#   validated JWT on every request. Unauthenticated requests never reach Grocy.
#
# Pre-flight (one-time):
#   * Add both household members to the PocketID "home" group, otherwise the
#     caddySecurity.home policy will deny them at the edge.
#   * No SOPS secrets required (SQLite backend, no SMTP, auth delegated to Caddy).

{ config, lib, mylib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "grocy";
  serviceDomain = "grocy.${config.networking.domain}";

  # grocy's bundled nginx listens here on loopback; Caddy reverse-proxies to it.
  nginxPort = 9970;

  # Upstream module default dataDir; backed by a dedicated ZFS dataset.
  dataDir = "/var/lib/grocy";
  dataset = "tank/services/grocy";

  serviceEnabled = config.services.grocy.enable or false;
in
{
  config = lib.mkMerge [
    {
      services.grocy = {
        enable = true;
        hostName = serviceDomain;
        dataDir = dataDir;

        # Caddy terminates TLS and owns ACME; grocy's nginx stays plain-HTTP on
        # loopback. (Setting this false also stops the upstream module from
        # adding enableACME/forceSSL to the vhost.)
        nginx.enableSSL = false;

        settings = {
          currency = "USD";
          culture = "en_GB";
        };

        # Trusted-header SSO — see the header notes in the file banner above.
        extraConfig = ''
          Setting('AUTH_CLASS', 'Grocy\Middleware\ReverseProxyAuthMiddleware');
          Setting('REVERSE_PROXY_AUTH_HEADER', 'X-Token-User-Email');
        '';
      };

      # Pin grocy's nginx vhost to loopback so it never competes with Caddy for
      # :80/:443. This overrides the upstream module's default (port 80) listen.
      services.nginx.virtualHosts.${serviceDomain}.listen = [
        { addr = "127.0.0.1"; port = nginxPort; }
      ];

      # Pin a stable uid for durable ZFS ownership across rebuilds / DR restore.
      # (Primary group stays "nginx" as forced by the upstream module.)
      users.users.grocy.uid = mylib.serviceUids.grocy.uid;

      # Caddy edge: TLS + PocketID SSO, proxying to grocy's loopback nginx.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = "127.0.0.1";
          port = nginxPort;
        };
        # Browser traffic: enforce PocketID "home" group and inject
        # X-Token-User-Email upstream (consumed by ReverseProxyAuthMiddleware).
        #
        # /api/* is exempted from the SSO gate (bypassPaths) and protected
        # instead by Grocy's own GROCY-API-KEY header auth — Grocy's middleware
        # runs ApiKeyAuthMiddleware before the reverse-proxy header lookup, so
        # non-browser clients (e.g. MCP tooling) can reach the REST API with an
        # API key. Mirrors the *arr `mediaWithApiBypass` pattern.
        #
        # SECURITY: this widens /api to be protected by the Grocy API key alone
        # (no PocketID). The key is a strong secret and must be treated as such.
        # Unauthenticated /api requests still fail closed (Grocy throws when no
        # API key and no identity header are present).
        caddySecurity = forgeDefaults.caddySecurity.home // {
          bypassPaths = [ "/api" ];
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # Don't let PHP-FPM start writing the SQLite DB before the ZFS dataset is
      # mounted (otherwise data lands on the rpool fallback and gets shadowed).
      systemd.services.phpfpm-grocy.unitConfig.RequiresMountsFor = [ dataDir ];

      # ZFS dataset for the SQLite DB + uploaded storage.
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = dataDir;
        recordsize = "16K"; # SQLite page-aligned writes
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "grocy";
        group = "nginx"; # primary group forced by the upstream grocy module
        mode = "0750";
      };

      # ZFS snapshots + replication to nas-1 via the standard forge template.
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      # Restic backup. The upstream module doesn't plug into the unified
      # modules.services.<name>.backup auto-discovery, so register the job
      # manually (same pattern as replog / whiskey-whiskey-whiskey).
      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ dataDir ];
        tags = [ "grocy" "sqlite" "household" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      # Service-down alert keyed on the PHP-FPM unit (the long-running process).
      modules.alerting.rules."grocy-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "phpfpm-grocy"
          "Grocy"
          "household & groceries management";

      # Gatus blackbox check through the full Caddy + SSO path. Unauthenticated
      # probes get redirected to the PocketID portal (302), which is healthy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Grocy";
        group = "applications";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
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
