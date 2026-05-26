# hosts/forge/services/replog.nix
#
# RepLog — self-hosted workout / family fitness tracking on forge.
# Upstream: https://github.com/carpenike/replog
#
# Architecture:
#   browser ─► Cloudflare Tunnel (forge) ──► Caddy ──► Go binary (127.0.0.1:5008)
#                                                          │
#                                                          ▼
#                                          /var/lib/replog/replog.db (+ WAL/SHM)
#                                          /var/lib/replog/avatars/
#
# Auth model:
#   * RepLog uses native WebAuthn passkeys, NOT PocketID/OIDC. The Caddy
#     vhost is a pure pass-through (no caddySecurity).
#   * REPLOG_BASE_URL drives WebAuthn RPID + Origins; the upstream module
#     auto-derives those when we set `baseUrl`. Do not split the hostname
#     across multiple origins without also pinning REPLOG_WEBAUTHN_ORIGINS.
#
# Storage:
#   * Upstream module uses systemd DynamicUser + StateDirectory, so the
#     runtime UID is ephemeral. ZFS dataset is owned root:root 0700 and
#     systemd takes over via its StateDirectory bind-mount. Same pattern
#     as whiskey-whiskey-whiskey.
#
# Pre-flight (one-time setup before the first apply succeeds):
#   1. `sops hosts/forge/secrets.sops.yaml` and add the keys under
#      `replog:` shown in hosts/forge/secrets.nix. The admin_* keys are
#      only consumed on the very first boot (until a user row exists in
#      the DB); secret_key is the AES key that encrypts settings stored
#      in the DB and is auto-generated if absent — we set it explicitly
#      so a DB restore onto a fresh host stays decryptable.
#   2. `task nix:apply-nixos host=forge` to bring the service up.
#   3. Visit https://replog.holthome.net → log in with the admin
#      credentials → register a passkey → DONE. After that you can
#      remove `admin_user`/`admin_pass`/`admin_email` from SOPS and
#      re-apply; replog will ignore them once a user exists.

{ config, lib, inputs, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "replog";
  serviceDomain = "replog.${config.networking.domain}";

  listenAddr = "127.0.0.1";
  listenPort = 5008; # matches the upstream module example

  # Upstream module hard-codes `StateDirectory = "replog"` → this path.
  dataDir = "/var/lib/${serviceName}";
  dataset = "tank/services/${serviceName}";

  serviceEnabled = config.services.replog.enable or false;
in
{
  imports = [
    inputs.replog.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.replog = {
        enable = true;
        package = inputs.replog.packages.${pkgs.stdenv.hostPlatform.system}.default;

        host = listenAddr;
        port = listenPort;
        dataDir = dataDir;

        # Auto-derives REPLOG_WEBAUTHN_RPID + REPLOG_WEBAUTHN_ORIGINS.
        baseUrl = "https://${serviceDomain}";

        settings = {
          # Trust localhost (Caddy on the same box) so X-Forwarded-For
          # is honored for rate-limit accounting. Cloudflare Tunnel
          # terminates at the local cloudflared which talks to Caddy
          # over loopback.
          REPLOG_TRUSTED_PROXIES = "127.0.0.1/32,::1/128";
        };

        # Secrets merged in via SOPS template (see hosts/forge/secrets.nix).
        # File is root-readable only; systemd reads it before dropping to
        # the DynamicUser.
        environmentFile = config.sops.templates."replog-env".path;

        # Default off — Caddy on the same host fronts the service.
        openFirewall = false;
      };

      # Refuse to start the service if the ZFS dataset isn't mounted.
      # Same fix-forward we applied to whiskey-whiskey-whiskey on 2026-05-13:
      # without this, systemd's DynamicUser will happily write the SQLite
      # DB to the rpool fallback, then the dataset gets mounted on top and
      # silently hides the data.
      systemd.services.replog.unitConfig.RequiresMountsFor = [
        dataDir
      ];

      # Caddy vhost — pure pass-through; WebAuthn is handled by the app.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = listenAddr;
          port = listenPort;
        };
        cloudflare = {
          enable = true;
          tunnel = "forge";
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for SQLite + avatars.
      # owner=root is intentional: upstream module uses systemd DynamicUser
      # + StateDirectory, so the runtime UID is ephemeral. systemd
      # bind-mounts /var/lib/private/replog into place and chowns *that*
      # path to the DynamicUser; the ZFS mountpoint at /var/lib/replog
      # only needs to be root:root 0700 for systemd to do the bind.
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

      # Restic backup. The upstream service uses DynamicUser, so it doesn't
      # plug into the unified `modules.services.<name>.backup` auto-discovery
      # path — register the job manually, exactly like whiskey-whiskey-whiskey.
      # `useSnapshots = true` gives us a consistent SQLite snapshot at backup
      # time.
      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ dataDir ];
        tags = [ serviceName "sqlite" "fitness" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      # Service-down alert (native systemd unit).
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "RepLog"
          "Self-hosted workout / family fitness tracker";

      # Gatus blackbox check from the public side. Confirms the full
      # Cloudflare → tunnel → Caddy → app path is healthy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "RepLog";
        group = "applications";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [
          # Unauth'd root may serve the SPA shell (200) or redirect to
          # /login (302) depending on session state. Either is healthy.
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
