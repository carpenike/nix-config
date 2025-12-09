# TheLounge Dracula theme
# https://github.com/dracula/thelounge
#
# A dark theme using the popular Dracula color palette.
# Install via: modules.services.thelounge.plugins = [ pkgs.thelounge-theme-dracula ];
{ pkgs
, stdenv
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.thelounge-theme-dracula;
  pname = "thelounge-theme-dracula";
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
    description = "Dark theme for The Lounge IRC client using Dracula colors";
    homepage = "https://github.com/dracula/thelounge";
    license = pkgs.lib.licenses.mit;
  };
}
