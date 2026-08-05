# hosts/forge/services/valhalla.nix
#
# Valhalla — self-hosted OSM routing / map-matching engine on forge.
# Upstream: https://github.com/valhalla/valhalla (scripted Docker image).
#
# WHY THIS EXISTS
#   CoachIQ (carpenike/coachiq, running on the RV Pi) snaps recorded GPS
#   breadcrumb trails to the road network so trips render on real streets
#   instead of jagged corner-cutting lines. Map matching must stay on
#   self-hosted infra — the coach's location must never leave the LAN — so the
#   Pi calls THIS Valhalla over the LAN whenever it has connectivity. Matching
#   is lazy and offline-tolerant on the app side, so an offline coach simply
#   defers matching until it can reach forge again.
#
# WHY VALHALLA (not OSRM / Mapbox / Google)
#   * Self-hosted only (privacy) rules out Mapbox/Google.
#   * Valhalla's tiled graph uses far less RAM than OSRM for large extracts and
#     rebuilds incrementally when the OSM extract changes — important for a
#     coach that travels the whole US and will grow its extract over time.
#
# WHY A CONTAINER (not native)
#   Valhalla is not packaged in nixpkgs in a serve-ready form; the upstream
#   "scripted" image bakes the whole tile-build-then-serve workflow (download
#   PBF → build graph → tar → serve) behind environment variables. Wrapping
#   that natively would re-implement a large entrypoint for no benefit. This is
#   a specialized single-container service (no web UI, no SSO, LAN API only),
#   so it uses raw oci-containers like the other forge sidecar containers
#   (see ups.nix / music-assistant.nix) rather than the web-UI service factory.
#
# ⚠️ RESOURCE COST — READ BEFORE CHANGING THE EXTRACT ⚠️
#   This instance serves the WHOLE UNITED STATES (Geofabrik `us-latest`).
#   Steady-state SERVING is cheap: Valhalla mmaps the tile tar, so resident
#   memory is only a few GB (mostly reclaimable page cache) — fine on forge.
#   The expensive part is the ONE-TIME tile build (and any later rebuild when
#   the extract changes):
#     * Full-US `valhalla_build_tiles` + `build_admins` (spatialite over the
#       whole US) is a MULTI-HOUR build that can peak well above forge's spare
#       RAM (32 GB box, ~60 services, no disk swap, ARC capped at 8 GB).
#     * Disk: the built graph is ~40–60 GB on `tank` (677 GB free — fine).
#
#   HOST-SAFETY MECHANISM: the hard `--memory` cgroup cap below CONTAINS any
#   build OOM to this container — the kernel reclaims ZFS ARC and kills inside
#   this cgroup before touching the other services. `server_threads` is kept
#   low (2) to bound the build's peak RAM. Net effect: worst case the build
#   itself is killed (recoverable), NOT the rest of forge. If the build can't
#   fit, fall back to the off-box tar path (see below); serving needs little.
#
# OFF-BOX BUILD FALLBACK (safest for a 32 GB box)
#   Build `valhalla_tiles.tar` on a machine with more RAM (or a throwaway VM):
#     docker run --rm -v $PWD/cf:/custom_files \
#       -e tile_urls=https://download.geofabrik.de/north-america/us-latest.osm.pbf \
#       -e build_admins=True -e build_time_zones=True \
#       ghcr.io/valhalla/valhalla-scripted:latest
#   then copy the resulting files to forge's ${dataDir}, set
#   use_tiles_ignore_pbf=True / force_rebuild=False (already the case), and add
#   the tar's md5 to ${dataDir}/.file_hashes.txt. No heavy build runs on forge.
#
# HOW TO GROW/CHANGE THE MAP
#   Change `tileUrls` (or drop `*.osm.pbf` files into ${dataDir}) and restart;
#   the image rebuilds tiles when the set of PBFs changes (md5 hashing). NOTE:
#   when shrinking/replacing the extract, delete stale PBFs from ${dataDir}
#   first (e.g. the old pennsylvania-latest.osm.pbf) or the image will rebuild
#   from ALL PBFs present. Upstream recommends a single merged extract over
#   many URLs for large builds (valhalla/valhalla#3925).
#
# ENDPOINT
#   The app posts to  http://forge.holthome.net:8002/trace_route  with
#   {"shape":[{lat,lon}…],"costing":"auto","shape_match":"map_snap"} and gets
#   back matched geometry (encoded polyline, precision 6). This matches the
#   `matching_url` default baked into CoachIQ's TripLogSettings.
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };

  serviceName = "valhalla";

  # LAN-facing: the RV Pi (and anything else on holthome) reaches this directly.
  # holthome is a trusted LAN, and there is no SSO in front (machine-to-machine
  # routing API), so we publish on all interfaces and open the port below.
  listenAddress = "0.0.0.0";
  port = 8002; # upstream default; also CoachIQ's matching_url default

  # Everything Valhalla generates (tiles, valhalla.json, admin/timezone DBs)
  # lives under /custom_files inside the container → this bind mount. The ZFS
  # dataset (tank/services/valhalla) is provisioned by the storage block below.
  dataDir = "/data/valhalla";

  # Whole United States. Geofabrik's `us-latest` is a single merged extract
  # (upstream recommends one extract over many state URLs — valhalla#3925).
  # See the RESOURCE COST / OFF-BOX BUILD notes in the header before changing.
  tileUrls = "https://download.geofabrik.de/north-america/us-latest.osm.pbf";

  # Keep the build single-/low-threaded so its peak RAM stays bounded on this
  # 32 GB box; combined with the container memory cap below, a hungry full-US
  # build is contained to this cgroup rather than OOM-ing the host. Raising
  # this speeds the build but increases peak RAM — do so only off-box.
  serverThreads = 2;
in
{
  # Active on import (same convention as ups.nix / music-assistant.nix).
  virtualisation.oci-containers.containers.${serviceName} = {
    # Upstream's latest channel currently has no equivalent release tag; pin
    # its content digest so Renovate can update it explicitly.
    image = "ghcr.io/valhalla/valhalla-scripted:latest@sha256:e454d110227a83804785ff271628d36548388777939f5e18a887ee1bc3f0ffef";
    autoStart = true;

    environment = {
      TZ = config.time.timeZone;
      # First run: download + build from these extract(s). Subsequent restarts
      # reuse the built tile tar unless the PBF set changes.
      tile_urls = tileUrls;
      use_tiles_ignore_pbf = "True"; # serve existing tiles; rebuild only on PBF change
      force_rebuild = "False";
      build_admins = "True"; # driving side + border-crossing penalties
      build_time_zones = "True"; # time-dependent costing
      serve_tiles = "True";
      server_threads = toString serverThreads;
    };

    # Persist the whole Valhalla working dir on the ZFS dataset below.
    volumes = [ "${dataDir}:/custom_files:rw" ];

    # Publish the routing API on the LAN.
    ports = [ "${listenAddress}:${toString port}:8002" ];

    extraOptions = [
      # HARD memory cap = host-safety boundary: any OOM during the multi-hour
      # full-US tile build is contained to this container (kernel reclaims ARC
      # + kills inside this cgroup) instead of taking down the other ~60
      # services on this 32 GB box. Steady-state serving needs only a few GB;
      # the headroom is for the build. If the full-US build gets OOM-killed
      # here, use the off-box tar path in the header rather than raising this.
      "--memory=14g"
      "--memory-reservation=2g"
      "--cpus=6.0"
    ];
  };

  # Never let the tile build land on the rpool fallback path and then get hidden
  # when the dataset mounts later (same guard as music-assistant).
  systemd.services."${config.virtualisation.oci-containers.backend}-${serviceName}".unitConfig.RequiresMountsFor =
    [ dataDir ];

  # Open the routing port to the trusted LAN so the RV Pi can reach it.
  networking.firewall.allowedTCPPorts = [ port ];

  # ZFS dataset for the tile graph. recordsize=1M suits the large, mostly
  # sequential tile tar. Snapshots/replication are intentionally OFF: the tiles
  # are fully rebuildable from the OSM extract, so backing up tens of GB would
  # be pure waste. (Hence no modules.backup.sanoid entry for this dataset.)
  modules.storage.datasets.services.${serviceName} = {
    mountpoint = dataDir;
    recordsize = "1M";
    compression = "zstd";
    properties."com.sun:auto-snapshot" = "false";
    # The scripted image manages ownership of /custom_files itself (it chowns to
    # its internal valhalla user on start), so root:root 0755 is sufficient.
    owner = "root";
    group = "root";
    rootOwnedReason = "The scripted image initializes /custom_files as root and then assigns its internal runtime ownership.";
    mode = "0755";
    protection = {
      class = "ephemeral";
      objectives = {
        onsiteRpoSeconds = null;
        offsiteRpoSeconds = null;
        rtoSeconds = null;
      };
      requiredTiers = [ ];
      consistency = "crash-consistent";
      validator = null;
      allowEmptyBootstrap = true;
      mechanism = {
        name = "none";
        reason = "The tile graph is reproducible from the configured OSM extract.";
      };
    };
  };

  # Alert if the container's systemd unit stops (node_exporter systemd collector,
  # same helper cooklang-federation uses — robust for any systemd unit).
  modules.alerting.rules."valhalla-service-down" =
    forgeDefaults.mkSystemdServiceDownAlert
      "${config.virtualisation.oci-containers.backend}-${serviceName}"
      "Valhalla"
      "OSM routing / map-matching engine (CoachIQ snap-to-road)";
}
