# TheLounge Mininapse theme
# https://github.com/MiniDigger/thelounge-theme-mininapse
#
# A dark, minimal theme for The Lounge IRC client.
# Install via: modules.services.thelounge.plugins = [ pkgs.thelounge-theme-mininapse ];
{ pkgs
, stdenv
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.thelounge-theme-mininapse;
  pname = "thelounge-theme-mininapse";
in
stdenv.mkDerivation {
  inherit pname;
  inherit (packageData) src version;

  installPhase = ''
    runHook preInstall

    # TheLounge expects plugins in lib/node_modules/<package-name>/
    mkdir -p $out/lib/node_modules/${pname}
    cp -r . $out/lib/node_modules/${pname}/

    runHook postInstall
  '';

  meta = {
    description = "Dark, minimal theme for The Lounge IRC client";
    homepage = "https://github.com/MiniDigger/thelounge-theme-mininapse";
    license = pkgs.lib.licenses.mit;
  };
}
