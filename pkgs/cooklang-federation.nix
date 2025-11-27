{ lib, pkgs, rustPlatform, fetchFromGitHub, ... }:
let
  version = "unstable-2025-11-17";

  src = fetchFromGitHub {
    owner = "cooklang";
    repo = "federation";
    rev = "1690f4554e74b66ca875162955a301b7ca99a79c";
    hash = "sha256-G3XyM5LFbfcTF3OBLyi24i5DB/hD04calpQN4EcH8hU=";
  };

in
rustPlatform.buildRustPackage {
  pname = "cooklang-federation";
  inherit version src;

  cargoHash = "sha256-DaM87ROyA8phsUIUf8pNv62w+VnF5cSNBm+dkDyUm+Y=";

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
