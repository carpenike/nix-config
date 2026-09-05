{ lib
, pkgs
, rustPlatform
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  src = sourceData.cooklang-cli;

  # Front-end assets are gitignored upstream, so the source tarball lacks them.
  # Since 0.33.0 build.rs hard-fails when either is missing (upstream #404), so
  # both the Tailwind stylesheet and the CodeMirror editor bundle have to be
  # produced here and dropped into the Rust source tree before cargo runs.
  frontendAssets = pkgs.buildNpmPackage {
    pname = "cooklang-frontend-assets";
    inherit (src) version;
    inherit (src) src;
    npmDepsHash = "sha256-ZSRd4tcAsR1tKZ8ZBcb95C1FWEaijsA0WQ5EME0cOfo=";

    # Two build scripts, so npmBuildScript (singular) does not fit.
    buildPhase = ''
      runHook preBuild
      npm run build-css
      npm run build-js
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 static/css/output.css $out/static/css/output.css
      install -Dm644 static/js/editor.bundle.js $out/static/js/editor.bundle.js
      runHook postInstall
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "cooklang-cli";
  inherit (src) version;
  inherit (src) src;

  cargoHash = "sha256-i8vE4iMe8JfghR2k9pNP3CkZlXP+87eF3MZfCBLxhiM=";

  nativeBuildInputs = [ pkgs.perl ];

  # Upstream's default feature set includes `self-update`, which adds a
  # `cook update` subcommand that downloads a release binary over the running
  # one. That can only fail against a read-only Nix store, and updates come
  # from nvfetcher here anyway. Everything else upstream enables by default is
  # kept, so only `cook update` disappears.
  buildNoDefaultFeatures = true;
  buildFeatures = [
    "server"
    "sync"
    "import"
    "lsp"
  ];

  preBuild = ''
    install -Dm644 ${frontendAssets}/static/css/output.css static/css/output.css
    install -Dm644 ${frontendAssets}/static/js/editor.bundle.js static/js/editor.bundle.js
  '';

  doCheck = false;

  meta = with lib; {
    description = "Cooklang CLI with embedded recipe web server";
    homepage = "https://github.com/cooklang/CookCLI";
    license = licenses.mit;
    mainProgram = "cook";
    maintainers = [ ];
    platforms = platforms.unix;
  };
}
