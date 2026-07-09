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
#   Tile size and the first-run build cost scale with the OSM extract:
#     * A single US state (the default below, ~Pennsylvania): ~a few GB of
#       tiles, a few minutes to build, serves in ~1–2 GB RAM.
#     * "north-america-latest" (the whole continent): tens of GB of disk and a
#       MULTI-HOUR, multi-GB-RAM tile build. Do NOT point `tileUrls` at the
#       continental extract without first raising `memory`, `serverThreads`,
#       and the dataset's expected size, and expect a long first deploy.
#   Start regional (states you actually travel), prove it out end-to-end with
#   the app, then grow. The tile data is REBUILDABLE from OSM, so this dataset
#   is deliberately NOT snapshotted or replicated (see the storage block).
#
# HOW TO GROW THE MAP
#   Either add more (space-separated) Geofabrik URLs to `tileUrls`, or drop
#   extra `*.osm.pbf` files into the dataset dir (${dataDir}) and restart the
#   container — the image rebuilds tiles when the set of PBFs changes (md5
#   hashing). Upstream now recommends a single merged extract over many URLs
#   for large builds (valhalla/valhalla#3925).
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

  # Start regional. Space-separated list of Geofabrik PBF URLs the image will
  # download and build on first run. Add neighbouring states as the coach's
  # range grows (or drop PBFs into ${dataDir} and restart).
  tileUrls = "https://download.geofabrik.de/north-america/us/pennsylvania-latest.osm.pbf";

  # Tile builds are CPU/RAM hungry. Keep threads modest so the build can't OOM
  # the box; raise for larger extracts (and lower if the builder gets killed).
  serverThreads = 4;
in
{
  # Active on import (same convention as ups.nix / music-assistant.nix).
  virtualisation.oci-containers.containers.${serviceName} = {
    # NOTE: pin to a digest via Renovate on first deploy (repo convention — see
    # peanut/bgutil). Left as a floating tag here to avoid committing a guessed
    # digest; Renovate will rewrite this to image@sha256:… .
    image = "ghcr.io/valhalla/valhalla-scripted:latest";
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
      # Serving is light; the first-run tile build is the heavy part. These
      # limits suit a single-state extract — raise them for larger extracts.
      "--memory=4g"
      "--memory-reservation=1g"
      "--cpus=4.0"
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
    mode = "0755";
  };

  # Alert if the container's systemd unit stops (node_exporter systemd collector,
  # same helper cooklang-federation uses — robust for any systemd unit).
  modules.alerting.rules."valhalla-service-down" =
    forgeDefaults.mkSystemdServiceDownAlert
      "${config.virtualisation.oci-containers.backend}-${serviceName}"
      "Valhalla"
      "OSM routing / map-matching engine (CoachIQ snap-to-road)";
}
