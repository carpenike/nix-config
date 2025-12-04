{ pkgs
, lib
, buildGoModule
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.kubectl-pgo;
in
buildGoModule rec {
  inherit (packageData) pname src;
  version = lib.strings.removePrefix "v" packageData.version;
  vendorHash = "sha256-2w3pccBAYwj1ucEAIr+31xWdxJBz3P9HrsIamTmBJXU=";

  doCheck = false;

  meta = {
    description = "Kubernetes CLI plugin to manage Crunchy PostgreSQL Operator resources.";
    mainProgram = "kubectl-pgo";
    homepage = "https://github.com/CrunchyData/postgres-operator-client";
    changelog = "https://github.com/CrunchyData/postgres-operator-client/releases/tag/v${version}";
  };
}
