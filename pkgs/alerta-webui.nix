# Alerta Web UI - Static frontend for the Alerta alert management system
#
# This package fetches the pre-built webui release from GitHub.
# The webui is a Vue.js SPA that talks to the alerta-server API.
#
# Version updates are tracked via nvfetcher (see nvfetcher.toml).
# Note: We use nvfetcher for version tracking only; the actual fetch
# is a tarball from the GitHub releases page (not the source repo).
#
{ lib, pkgs, ... }:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  versionInfo = sourceData.alerta-webui;
  # Strip the 'v' prefix from the version for the URL
  version = lib.removePrefix "v" versionInfo.version;
in
pkgs.stdenv.mkDerivation {
  pname = "alerta-webui";
  inherit version;

  # The GitHub release is a tarball containing the built dist/ directory
  # This is different from the source - it's the pre-built Vue.js app
  src = pkgs.fetchzip {
    url = "https://github.com/alerta/alerta-webui/releases/download/v${version}/alerta-webui.tar.gz";
    # Hash for v8.7.1 - update this when version changes
    sha256 = "sha256-daPQqjoLErS95PNJG0IXCbM/atOsJ5jGk1mqB1qhCPg=";
    stripRoot = false;
  };

  # No build needed - just install the pre-built files
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/alerta-webui
    cp -r dist/* $out/share/alerta-webui/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Web UI for the Alerta alert management system";
    homepage = "https://github.com/alerta/alerta-webui";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.all;
  };
}
