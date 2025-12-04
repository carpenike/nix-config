{ lib, pkgs, rustPlatform, ... }:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  src = sourceData.cooklang-federation;
in
rustPlatform.buildRustPackage {
  pname = "cooklang-federation";
  inherit (src) version;
  inherit (src) src;

  cargoHash = "sha256-gGBboChD9bgxGtSQck4UaokVf4yY0F/o7ifTClkScEQ=";

  patches = [
    ./patches/cooklang-federation-normalize-field-query.patch
  ];

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
