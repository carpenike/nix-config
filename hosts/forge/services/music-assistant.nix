# hosts/forge/services/music-assistant.nix
#
# Music Assistant — self-hosted music library manager + multi-room media
# server on forge. Aggregates streaming/library music providers and streams to
# a wide range of players (Chromecast, Sonos, DLNA/UPnP, AirPlay, Snapcast, …).
# Upstream: https://music-assistant.io
#
# Why NATIVE (services.music-assistant) instead of a container:
#   Per .github/instructions/nixos-instructions.md the rule is "native when the
#   service is in nixpkgs". Music Assistant IS in nixpkgs (the upstream module
#   ships the systemd unit + provider dependency wiring), and it relies heavily
#   on host-network multicast (mDNS / UPnP-SSDP) to discover players — exactly
#   the case where a native host-networked service is simpler and more correct
#   than a bridged container (which would need host/macvlan networking anyway).
#   Forge already runs avahi + has multicast tuning (see core/system-services.nix
#   and core/networking.nix), so discovery works out of the box.
#
# Architecture:
#   browser ─► Caddy (TLS + PocketID SSO) ──► MA web UI/API (127.0.0.1:8095)
#
#   Home Assistant ─(WebSocket API)─► MA server (127.0.0.1:8095)
#                       via the core `music_assistant` integration, whose
#                       Python dep `music-assistant-client` is already wired
#                       into HA (see services/home-assistant.nix extraPackages).
#
#   players ◄─(audio stream)── MA stream server (LAN :8097)
#
#   Ports (from the upstream module / docs):
#     * 8095/tcp — web UI + WebSocket API (what humans and HA connect to).
#                  NOT opened in the firewall; reached only via Caddy (humans)
#                  or loopback (HA on the same box).
#     * 8097/tcp — audio stream server; players fetch the rendered stream here.
#                  Opened on the LAN manually below so players can reach it.
#                  (The pinned nixpkgs module has no `openFirewall` option, so
#                  we open the stream port ourselves; add provider-specific
#                  ports here too if you enable airplay/snapcast/squeezelite/…)
#
# Auth model:
#   Music Assistant has NO built-in authentication, so the human-facing web UI
#   is gated at the edge by Caddy + PocketID SSO (caddySecurity.home — requires
#   the "home" group). The HA integration and players bypass Caddy: HA connects
#   over loopback (127.0.0.1:8095) and players pull audio from the LAN stream
#   port, so SSO never blocks machine-to-machine traffic. The web UI port (8095)
#   is deliberately left out of the firewall so the only browser path is through
#   the authenticated Caddy vhost.
#
# Providers:
#   Music/player providers are configured at runtime in the MA web UI and stored
#   (encrypted) in MA's own database — no Nix changes needed for most of them
#   (Chromecast, Sonos, DLNA, Spotify-via-token, etc.). The `providers` option
#   below only installs EXTRA system binaries for the providers that need them
#   (this pinned nixpkgs revision wires up: "spotify" → librespot-ma,
#   "snapcast" → snapcast, "ytmusic" → deno + ffmpeg). Start with none; add here
#   as you enable matching providers in the UI, and open any extra ports they
#   need in the firewall block below (e.g. snapcast 1780/tcp).
#
# YouTube Music PO tokens:
#   Since Google's March 2025 "Proof of Origin" (PO token) rollout, MA cannot
#   resolve YouTube Music stream URLs without a reachable PO-token server, and
#   the YT Music provider config validates this. We run the supported server
#   (brainicism/bgutil-ytdlp-pot-provider, pinned to MA's required v1.2.1) as a
#   stateless loopback container (see the `bgutil-pot` container below), and set
#   the provider's "PO Token Server URL" to http://127.0.0.1:4416.
#
# Storage (DynamicUser + ZFS):
#   The upstream module runs under systemd `DynamicUser` + `StateDirectory =
#   "music-assistant"` (→ /var/lib/music-assistant), so the runtime UID is
#   ephemeral. The backing ZFS dataset is therefore owned root:root 0700 and
#   systemd manages runtime ownership via its StateDirectory bind-mount — the
#   same proven pattern as replog / whiskey-whiskey-whiskey. `RequiresMountsFor`
#   guarantees the dataset is mounted before first write so MA's library DB
#   never lands on the rpool fallback and then gets hidden by the later mount.
#
# Pre-flight (one-time):
#   * Add household members to the PocketID "home" group (caddySecurity.home),
#     otherwise the edge denies them.
#   * After deploy: in Home Assistant add the "Music Assistant" integration and
#     point it at the server URL `http://127.0.0.1:8095` (co-located) — or let
#     it auto-discover via mDNS.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "music-assistant";
  serviceDomain = "music.${config.networking.domain}";

  listenAddr = "127.0.0.1";
  webPort = 8095; # MA web UI + WebSocket API (upstream default)

  # bgutil PO-token provider (required by the YouTube Music provider, see the
  # "YouTube Music PO tokens" note in the header). Stateless HTTP server, default
  # port 4416, reached by MA over loopback.
  potPort = 4416;

  # Upstream module hard-codes `StateDirectory = "music-assistant"` and the
  # `--config /var/lib/music-assistant` default → this path.
  dataDir = "/var/lib/${serviceName}";
  dataset = "tank/services/${serviceName}";

  serviceEnabled = config.services.music-assistant.enable or false;
in
{
  config = lib.mkMerge [
    {
      services.music-assistant = {
        enable = true;

        # Extra system binaries for providers that need them. Add entries here
        # as you enable the matching providers in the MA web UI (see header).
        #   "spotify" → pulls in librespot-ma, required by MA's Spotify music
        #   provider. Needs a Spotify Premium account, configured at runtime in
        #   the MA web UI (Settings → Music Providers → Spotify). No Nix secret
        #   and no extra firewall port: librespot connects outbound to Spotify
        #   and the rendered audio is still served via the 8097 stream port.
        #   "ytmusic" → pulls in deno + ffmpeg (deno runs yt-dlp challenge
        #   solvers with JIT, so the module also relaxes MemoryDenyWriteExecute
        #   for this unit). Needs a YouTube Music account, authenticated at
        #   runtime in the MA web UI. No Nix secret and no extra firewall port
        #   (outbound to Google; audio served via the 8097 stream port).
        #   YouTube Music ALSO requires a PO-token server (see header + the
        #   bgutil container below) — set its URL to http://127.0.0.1:4416 in
        #   the YT Music source config.
        #   "sonos" → installs the Sonos (S2) player dependency. Discovery uses
        #   the host's mDNS/UPnP multicast (avahi is already enabled on forge);
        #   players stream from the open 8097 port, so no extra firewall change.
        #   (Use "sonos_s1" instead for legacy S1 systems.)
        providers = [ "spotify" "ytmusic" "sonos" ];
      };

      # Open the LAN-facing audio stream port so players can fetch the rendered
      # stream. The pinned nixpkgs module opens no ports itself. The web UI port
      # (8095) is deliberately NOT opened — humans go through Caddy, HA goes
      # through loopback. Add provider-specific ports here if you enable them
      # (e.g. snapcast 1780/tcp, slimproto 3483/9000/9090).
      networking.firewall.allowedTCPPorts = [ 8097 ];

      # Refuse to start until the ZFS dataset is mounted, otherwise systemd's
      # DynamicUser would write MA's library DB to the rpool fallback path and
      # the dataset mount would later silently hide it. (Same fix-forward as
      # replog / whiskey-whiskey-whiskey.)
      systemd.services.music-assistant.unitConfig.RequiresMountsFor = [ dataDir ];

      # Caddy edge: TLS + PocketID SSO in front of MA's unauthenticated web UI.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = listenAddr;
          port = webPort;
        };
        # Household access via the PocketID "home" group.
        caddySecurity = forgeDefaults.caddySecurity.home;
      };

      # bgutil PO-token provider for the YouTube Music source. Since Google's
      # March 2025 "Proof of Origin" rollout, Music Assistant cannot resolve
      # YouTube Music stream URLs without a PO token, and MA's YT Music provider
      # validates that a reachable PO-token server is configured. This is the
      # self-hosted equivalent of the "YT Music PO Token Generator" HA add-on.
      #
      # Stateless sidecar: no persistence, no reverse proxy. MA reaches it over
      # loopback at http://127.0.0.1:4416 (set that as the "PO Token Server URL"
      # in the YT Music source config).
      #
      # VERSION PIN: MA bundles a matching bgutil plugin and only supports a
      # specific server version — currently 1.2.1 (per the MA YouTube Music
      # docs). Do NOT let Renovate bump this independently; update it only when
      # MA's supported PO-token server version changes.
      virtualisation.oci-containers.containers.bgutil-pot = {
        image = "docker.io/brainicism/bgutil-ytdlp-pot-provider:1.3.1@sha256:1aaa43a0ca72dfca6a6d2129a0fb4a23465c25adb1b043f8aff829a20825646b";
        autoStart = true;

        environment = {
          TZ = config.time.timeZone;
        };

        # Loopback only — consumed by Music Assistant on the same host.
        ports = [
          "127.0.0.1:${toString potPort}:4416"
        ];

        extraOptions = [
          # The server forks a headless runtime to mint tokens; --init reaps it.
          "--init"
          # Token generation (botguard/canvas) is bursty but light.
          "--memory=512m"
          "--memory-reservation=128m"
          "--cpus=1.0"
        ];
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for MA's library database + metadata cache.
      # owner=root is intentional: the upstream module uses systemd DynamicUser
      # + StateDirectory, so the runtime UID is ephemeral. systemd bind-mounts
      # the StateDirectory into place and chowns it to the DynamicUser; the ZFS
      # mountpoint only needs to be root:root 0700 for systemd to do the bind.
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

      # Restic backup. The upstream module uses DynamicUser, so it doesn't plug
      # into the unified `modules.services.<name>.backup` auto-discovery — register
      # the job manually (same pattern as replog / whiskey-whiskey-whiskey).
      # `useSnapshots = true` gives a consistent snapshot of MA's SQLite library.
      modules.services.backup.restic.jobs.${serviceName} = {
        enable = true;
        repository = forgeDefaults.backup.repository;
        paths = [ dataDir ];
        tags = [ serviceName "music" "home-automation" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      # Service-down alert (native systemd unit).
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          serviceName
          "Music Assistant"
          "music library & multi-room player server";

      # Service-down alert for the PO-token sidecar (YouTube Music breaks
      # silently without it).
      modules.alerting.rules."bgutil-pot-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "podman-bgutil-pot"
          "Music Assistant PO-Token Server"
          "YouTube Music PO-token generator";

      # Gatus blackbox check through the full Caddy + SSO path. An
      # unauthenticated probe is redirected to the PocketID portal (302),
      # which is healthy.
      modules.services.gatus.contributions.${serviceName} = {
        name = "Music Assistant";
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
