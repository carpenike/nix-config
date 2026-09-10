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
, fetchFromGitHub
, buildNpmPackage
, nodejs_22
, node-gyp
, pkg-config
, vips
, python3
, makeWrapper
}:

buildNpmPackage rec {
  pname = "worldmonitor";
  # renovate: depName=koala73/worldmonitor datasource=github-releases
  version = "2.10.0";

  src = fetchFromGitHub {
    owner = "koala73";
    repo = "worldmonitor";
    rev = "v${version}";
    hash = "sha256-QPOc2tc9pdRZuSQ1biaaoZv0xjO7TkZJGRzEBrlmazw=";
  };

  npmDepsHash = "sha256-L+/4AoMem5RQawU9c5YJLKp5BPeulIaZzy0U9xC46Ko=";

  nodejs = nodejs_22;
  NODE_PATH = "${node-gyp}/lib/node_modules";

  # WORKAROUND (2026-09-09): The root postinstall runs a second npm install
  # for blog-site, which this package neither builds nor installs.
  # Affects: WorldMonitor v2.10.0 Nix builds
  # Upstream: https://github.com/koala73/worldmonitor/blob/v2.10.0/package.json
  # Check: Remove when upstream no longer installs blog-site from postinstall.
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
