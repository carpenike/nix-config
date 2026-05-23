{ lib, pkgs, rustPlatform, ... }:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  src = sourceData.cooklang-federation;
in
rustPlatform.buildRustPackage {
  pname = "cooklang-federation";
  inherit (src) version;
  inherit (src) src;

  cargoHash = "sha256-jPoDiAAY6tGEYiRDrBETUZNXGfJ72n1m1zjjyrsXuBQ=";

  # WORKAROUND (2026-02-11): Wire RSS-crawled recipes into the Tantivy search index.
  # Affects: cooklang-federation (search/filter for RSS-sourced recipes)
  # Upstream: not filed (https://github.com/cooklang/federation — repo has no
  #   issue tracker enabled and is low-velocity; last commit 2026-04-13).
  # Check: re-evaluate when upstream `Crawler` gains a `search_index` field or
  #   when `index_recipes()` is called from `crawl_feed()`. As of upstream HEAD
  #   d4131c0b (2026-04-13), only the GitHub indexer writes to Tantivy, so RSS
  #   recipes are invisible to `/search` without this patch. The patch also
  #   adds the INDEXED flag to `servings`/`total_time` so range queries work.
  # See: docs/workarounds.md
  patches = [
    ./patches/cooklang-federation-normalize-field-query.patch
  ];

  # WORKAROUND (2026-02-11): Convert Tailwind v4 `@import` to v3 directives.
  # Affects: cooklang-federation CSS build at ExecStartPre (uses pkgs.tailwindcss_3)
  # Upstream: not filed (cooklang/federation issue tracker disabled). Upstream
  #   `styles/input.css` ships `@import "tailwindcss";` (Tailwind v4 syntax) but
  #   the repo has no `package.json` and `tailwind.config.js` is v3-format
  #   (`module.exports = { ... }`) — i.e. upstream is in a broken hybrid state
  #   and cannot actually build its own CSS without external tooling.
  # Check: when upstream either (a) completes the Tailwind v4 migration
  #   (adds `package.json`, replaces JS config with `@theme` blocks) — at which
  #   point switch the service module to `pkgs.tailwindcss_4` and drop this —
  #   or (b) reverts the input.css change back to v3 directives, in which case
  #   drop this and keep tailwindcss_3.
  # See: docs/workarounds.md
  postPatch = ''
        substituteInPlace styles/input.css \
          --replace '@import "tailwindcss";' '@tailwind base;
    @tailwind components;
    @tailwind utilities;'
  '';

  nativeBuildInputs = [
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.openssl
    pkgs.sqlite
  ];

  preFixup = ''
    srcDir="$NIX_BUILD_TOP/source/src"
    stylesDir="$NIX_BUILD_TOP/source/styles"
    configFile="$NIX_BUILD_TOP/source/tailwind.config.js"
    configDir="$NIX_BUILD_TOP/source/config"

      install -d $out/share/cooklang-federation

      if [ -d "$srcDir" ]; then
        cp -r --no-preserve=ownership "$srcDir" $out/share/cooklang-federation/
      fi
      if [ -d "$stylesDir" ]; then
        cp -r --no-preserve=ownership "$stylesDir" $out/share/cooklang-federation/
      fi
      if [ -d "$configDir" ]; then
        cp -r --no-preserve=ownership "$configDir" $out/share/cooklang-federation/
      fi
      if [ -f "$configFile" ]; then
        install -D "$configFile" $out/share/cooklang-federation/tailwind.config.js
      fi
  '';

  doCheck = false;

  meta = with lib; {
    description = "Cooklang Federation server for distributed recipe search";
    homepage = "https://github.com/cooklang/federation";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "federation";
    platforms = platforms.unix;
  };
}
