{ lib
, pkgs
, rustPlatform
, fetchFromGitHub
, ...
}:
let
  version = "0.18.2";

  src = fetchFromGitHub {
    owner = "cooklang";
    repo = "CookCLI";
    rev = "v${version}";
    hash = "sha256-uw1xwE7hIE00OADV9kOXR1/gKSzvleW1/5PwfhH4fvE=";
  };

  tailwindAssets = pkgs.buildNpmPackage {
    pname = "cooklang-tailwind-assets";
    inherit version src;
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
  inherit version src;

  cargoHash = "sha256-Yxln5eKNXONGd4Hy9Ru9t92iqK9zcTSpzu2j75bc3fk=";

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
