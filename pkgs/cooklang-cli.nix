{ lib
, pkgs
, rustPlatform
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  src = sourceData.cooklang-cli;

  tailwindAssets = pkgs.buildNpmPackage {
    pname = "cooklang-tailwind-assets";
    inherit (src) version;
    inherit (src) src;
    npmDepsHash = "sha256-HxC9Tf+PZvvETuNqm1W3jaZx7SpYXlxZlI8FwGouK+s=";
    npmBuildScript = "build-css";
    installPhase = ''
      runHook preInstall
      install -Dm644 static/css/output.css $out/static/css/output.css
      runHook postInstall
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "cooklang-cli";
  inherit (src) version;
  inherit (src) src;

  cargoHash = "sha256-xQTMxas5gO17DvNXvxdJ03Rhd4kaJPBf+GikbCE1fWI=";

  nativeBuildInputs = [ pkgs.perl ];

  preBuild = ''
    install -Dm644 ${tailwindAssets}/static/css/output.css static/css/output.css
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
