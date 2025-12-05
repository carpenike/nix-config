{ pkgs
, lib
, buildGoModule
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.kubectl-browse-pvc;
in
buildGoModule rec {
  inherit (packageData) pname src;
  version = lib.strings.removePrefix "v" packageData.version;
  vendorHash = "sha256-WwEFtiWP9rQnOjMNnY8nFBKvw0Gp29wcKrLrUqOr7DQ=";

  # Go source is in src/ subdirectory
  modRoot = "src";

  doCheck = false;

  postInstall = ''
    mv $out/bin/kubectl-browse-pvc $out/bin/kubectl-browse_pvc
  '';

  meta = {
    description = "Kubernetes CLI plugin for browsing PVCs on the command line";
    mainProgram = "kubectl-browse-pvc";
    homepage = "https://github.com/clbx/kubectl-browse-pvc";
    changelog = "https://github.com/clbx/kubectl-browse-pvc/releases/tag/v${version}";
  };
}
