# World Monitor package
# Builds the static frontend + API sidecar from the public GitHub repo.
#
# The sidecar is a standalone Node.js HTTP server that:
#   - Serves the Vite-built SPA from dist/
#   - Runs all 25+ API domain handlers locally
#   - Falls back to worldmonitor.app for failed local handlers
#
# Build produces:
#   $out/share/worldmonitor/dist/     — static frontend
#   $out/share/worldmonitor/api/      — compiled API handlers
#   $out/share/worldmonitor/src-tauri/sidecar/ — local API server
#   $out/bin/worldmonitor-api          — wrapper script

{ lib
, pkgs
, fetchFromGitHub
, buildNpmPackage
, nodejs_22
, node-gyp
, pkg-config
, vips
, python3
, makeWrapper
}:

let
  # nixpkgs 25.11 prefetch-npm-deps treats `resolved: "file:…"` as a URL and
  # panics when the entry has no integrity. v2.11.2 vendors braces and
  # stream-json that way. Later nixpkgs skips the file scheme; this is that
  # skip, scoped to this package's dependency fetch.
  prefetch-npm-deps = pkgs.prefetch-npm-deps.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ python3 ];
    postPatch = (old.postPatch or "") + ''
      python3 - <<'PY'
      from pathlib import Path
      path = Path("src/parse/lock.rs")
      text = path.read_text()
      old = ".filter(|(n, p)| !n.is_empty() && matches!(p.resolved, Some(UrlOrString::Url(_))))"
      new = """.filter(|(n, p)| {
                  !n.is_empty()
                      && match &p.resolved {
                          Some(UrlOrString::Url(url)) => url.scheme() != "file",
                          _ => false,
                      }
              })"""
      if old not in text:
          raise SystemExit("prefetch-npm-deps filter no longer matches")
      path.write_text(text.replace(old, new, 1))
      PY
    '';
  });
  fetchNpmDeps = pkgs.fetchNpmDeps.override {
    inherit prefetch-npm-deps;
  };
in

buildNpmPackage rec {
  pname = "worldmonitor";
  # renovate: depName=koala73/worldmonitor datasource=github-releases
  version = "2.11.2";

  src = fetchFromGitHub {
    owner = "koala73";
    repo = "worldmonitor";
    # v2.11.2 is annotated tag 3c7e907146cca28b661dd4cbebfa3a4901fb7b3c of this
    # commit (github-actions, 2026-10-20T06:15:46Z). GitHub release tags are
    # mutable, and `rev = "v${version}"` makes the fixed-output source follow
    # whatever the tag currently points at. Renovate's regex manager only
    # rewrites `version`, so a tag bump with this hash left stale fails the
    # fetch. Pin the commit; update rev and both hashes together with version.
    rev = "39c1a1e7571131d40038aeb8474809a8376c8cfa";
    hash = "sha256-M5xFoI7hhR1/KR2vnd+qxdELIJRFltsQAbZuAr3qu3Q=";
  };

  npmDepsHash = "sha256-EeoI6YKKz1eavM9yGWboVJZXHaZIknVOlZ2tpkiz5Sc=";

  # npm ci writes a temp dir inside the dependency cache. The fixed-output
  # cache is root-owned and read-only, so the install copies it first.
  makeCacheWritable = true;

  # buildNpmPackage's bundled fetcher is the unpatched one. Pass the fetcher
  # that skips vendored file: URLs; npm ci still installs those from vendor/.
  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    inherit src;
    hash = npmDepsHash;
  };

  nodejs = nodejs_22;
  NODE_PATH = "${node-gyp}/lib/node_modules";

  # v2.11.2's postinstall is `npm run inventory:facts`, which writes the
  # gitignored api/_inventory-facts.generated.js imported by the API.
  # npm ci --ignore-scripts skips it. Drop the script so npm rebuild cannot
  # start a nested install, and generate the module in buildPhase.
  # Upstream: https://github.com/koala73/worldmonitor/blob/39c1a1e7571131d40038aeb8474809a8376c8cfa/package.json
  postPatch = ''
    ${nodejs_22}/bin/node -e '
      const fs = require("node:fs");
      const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));
      delete packageJson.scripts.postinstall;
      fs.writeFileSync("package.json", JSON.stringify(packageJson, null, 2) + "\n");
    '
  '';

  # sharp (transitive dep via @xenova/transformers) needs:
  #   - pkg-config to detect system libvips (skips download)
  #   - vips (libvips) as the native image library
  #   - python3 for node-gyp to compile the C++ binding
  nativeBuildInputs = [ nodejs_22 node-gyp pkg-config python3 makeWrapper ];
  buildInputs = [ vips ];

  # The repo has TypeScript strict-mode errors that are non-fatal for the build
  # (the Vite build succeeds regardless). Skip the type check.
  buildPhase = ''
    runHook preBuild

    # Gitignored boot artifact. api/product-catalog.js imports it, and the
    # sidecar copies api/ into the output.
    node scripts/generate-inventory-facts.mjs

    # 1. Compile the sebuf RPC gateway (TS → single ESM bundle)
    node scripts/build-sidecar-sebuf.mjs

    # 2. Build the Vite SPA frontend → dist/
    npx vite build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/worldmonitor

    # Static frontend
    cp -r dist $out/share/worldmonitor/dist

    # API handlers (standalone .js files + sebuf gateway bundle)
    cp -r api $out/share/worldmonitor/api

    # Sidecar server entry point
    mkdir -p $out/share/worldmonitor/src-tauri/sidecar
    cp src-tauri/sidecar/local-api-server.mjs \
       $out/share/worldmonitor/src-tauri/sidecar/

    # Data files referenced by API handlers at runtime
    cp -r data $out/share/worldmonitor/data

    # Config files the sidecar imports
    mkdir -p $out/share/worldmonitor/src/config
    cp -r src/config/* $out/share/worldmonitor/src/config/

    # Server handler implementations (imported by sebuf gateway)
    cp -r server $out/share/worldmonitor/server

    # Runtime node_modules (needed by sidecar for @upstash/redis, etc.)
    cp -r node_modules $out/share/worldmonitor/node_modules

    # Wrapper script
    makeWrapper ${nodejs_22}/bin/node $out/bin/worldmonitor-api \
      --add-flags "$out/share/worldmonitor/src-tauri/sidecar/local-api-server.mjs"

    runHook postInstall
  '';

  # No meaningful tests to run during build
  doCheck = false;

  meta = with lib; {
    description = "World Monitor - real-time global intelligence dashboard";
    homepage = "https://github.com/koala73/worldmonitor";
    license = licenses.agpl3Only;
    maintainers = [ ];
    platforms = platforms.linux;
  };
}
