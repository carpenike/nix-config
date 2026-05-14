# hosts/forge/services/whiskeywhiskeywhiskey.nix
#
# Operation W.W.W. — World War Wednesdays Command Center on forge.
# Upstream: https://github.com/carpenike/whiskey-whiskey-whiskey
#
# Architecture:
#   browser  ─┐
#             ├─► Cloudflare Tunnel (forge) ──► Caddy ──► Fastify (127.0.0.1:3417)
#   claude   ─┘                                                 │
#                                                               ▼
#                                          /var/lib/whiskey-whiskey-whiskey/db.sqlite
#
# Notes:
#   * The upstream module uses `DynamicUser` + `StateDirectory`. systemd will
#     chown the ZFS mountpoint to the ephemeral UID on every service start, so
#     the dataset is configured with `root:root 0700` and we let systemd take
#     over. No entry in `lib/service-uids.nix` is required.
#   * The app handles OIDC natively against PocketID — we deliberately skip
#     `caddySecurity` on the vhost. Caddy is a pure pass-through.
#   * Cloudflare Tunnel DNS automation uses the API-mode token registered in
#     `cloudflare-tunnel.nix`, which already has scope for whiskeywhiskeywhiskey.org.
#
# Pre-flight (one-time setup before the first apply succeeds):
#   1. In PocketID admin → OIDC Clients → Add:
#        Client ID:           whiskey-whiskey-whiskey
#        Client Secret:       <generate; copy into secrets.sops.yaml below>
#        Callback URL:        https://whiskeywhiskeywhiskey.org/api/auth/callback
#        Logout URL:          https://whiskeywhiskeywhiskey.org/
#        Groups claim:        ensure `groups` is released to this client
#        Required groups:     `www-host` (full access), `www-crew` (read-only)
#   2. Create the PocketID groups `www-host` and `www-crew` and add at least
#      one host member, then assign the client to those groups.
#   3. Encrypt the following keys via `sops hosts/forge/secrets.sops.yaml`:
#        whiskey-whiskey-whiskey:
#          anthropic_api_key:    sk-ant-...
#          api_token:            <openssl rand -hex 32>           # external bearer (MCP, curl)
#          session_secret:       <openssl rand -hex 48>           # signs the session cookie
#          oidc_client_secret:   <from PocketID admin>
#
#      Optional: if you also want to grant host access by email address
#      (independent of the `www-host` group), add a comma-separated list to
#      `settings.WWW_HOST_EMAILS` below. The PocketID group is sufficient on
#      its own — we keep this out of SOPS so it diffs cleanly.
#
# After step 3, run `task nix:apply-nixos host=forge` to bring the service up.

{ config, lib, inputs, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "whiskeywhiskeywhiskey";
  apexDomain = "whiskeywhiskeywhiskey.org";
  wwwDomain = "www.${apexDomain}";
  cloudflareZone = apexDomain;
  pocketIdIssuer = "https://id.${config.networking.domain}";

  listenAddr = "127.0.0.1";
  listenPort = 3417; # matches the port hinted at in the upstream module example

  # systemd StateDirectory name; the upstream module hard-codes
  # `StateDirectory = "whiskey-whiskey-whiskey"`, which yields this path.
  stateDirName = "whiskey-whiskey-whiskey";
  dataDir = "/var/lib/${stateDirName}";
  dataset = "tank/services/${serviceName}";

  serviceEnabled = config.services.whiskey-whiskey-whiskey.enable or false;
in
{
  imports = [
    inputs.whiskey-whiskey-whiskey.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.whiskey-whiskey-whiskey = {
        enable = true;
        package = inputs.whiskey-whiskey-whiskey.packages.${pkgs.stdenv.hostPlatform.system}.default;

        host = listenAddr;
        port = listenPort;
        dataDir = dataDir;
        logLevel = "info";

        # Non-secret OIDC + role configuration. Visible in the Nix store.
        settings = {
          WWW_OIDC_ISSUER = pocketIdIssuer;
          WWW_OIDC_CLIENT_ID = "whiskey-whiskey-whiskey";
          WWW_OIDC_REDIRECT_URI = "https://${apexDomain}/api/auth/callback";
          WWW_HOST_GROUP = "www-host";
          WWW_CREW_GROUP = "www-crew";

          # Optional: email-based host allow-list (OR'd with WWW_HOST_GROUP).
          # Uncomment if you want a fallback path that doesn't rely on PocketID
          # group membership. Comma-separated, no spaces.
          # WWW_HOST_EMAILS = "you@example.com,other@example.com";
        };

        # Secrets are merged in via SOPS template (see hosts/forge/secrets.nix).
        # File is root-readable only; systemd reads it before dropping to the
        # DynamicUser.
        environmentFile = config.sops.templates."whiskey-whiskey-whiskey-env".path;

        # Default off — Caddy on the same host fronts the service.
        openFirewall = false;
      };

      # Caddy vhost — apex, canonical hostname. Pure pass-through; the app
      # does OIDC against PocketID itself, so no caddySecurity here.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = apexDomain;
        backend = {
          host = listenAddr;
          port = listenPort;
        };
        cloudflare = {
          enable = true;
          tunnel = "forge";
          dns.zoneName = cloudflareZone;
        };
      };

      # Caddy vhost — www → apex 301. handleOnly is required because we do
      # not define a `backend`; Caddy will just return the redirect.
      modules.services.caddy.virtualHosts."${serviceName}-www" = {
        enable = true;
        hostName = wwwDomain;
        handleOnly = true;
        extraConfig = ''
          redir https://${apexDomain}{uri} permanent
        '';
        cloudflare = {
          enable = true;
          tunnel = "forge";
          dns.zoneName = cloudflareZone;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for the SQLite state directory.
      # owner=root is intentional: the upstream module uses systemd
      # DynamicUser + StateDirectory, which means the runtime UID is
      # ephemeral and assigned by systemd at service start. systemd then
      # bind-mounts /var/lib/private/whiskey-whiskey-whiskey into place and
      # chowns *that* path to the DynamicUser. The actual ZFS mountpoint at
      # /var/lib/whiskey-whiskey-whiskey only needs to exist and be
      # accessible to root for systemd to do the bind. See the upstream
      # module's StateDirectoryMode = "0700" + DynamicUser = true.
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
          "whiskey-whiskey-whiskey"
          "WhiskeyWhiskeyWhiskey"
          "Operation W.W.W. command center";

      # Gatus blackbox check from the public side. Lets us know if the full
      # Cloudflare → tunnel → Caddy → app path is healthy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Whiskey Whiskey Whiskey";
        group = "applications";
        url = "https://${apexDomain}";
        interval = "60s";
        conditions = [
          # The SPA root is behind OIDC, so 200 or 302 are both healthy.
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
