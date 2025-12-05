{ pkgs
, lib
, ...
}:
let
  rustPlatform = pkgs.makeRustPlatform {
    cargo = pkgs.rust-bin.stable.latest.minimal;
    rustc = pkgs.rust-bin.stable.latest.minimal;
  };
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.usage-cli;
in
rustPlatform.buildRustPackage rec {
  inherit (packageData) pname src;
  version = lib.strings.removePrefix "v" packageData.version;
  cargoHash = "sha256-/vXoTMx3Je1nCAdRYJR+F3l7cZCbtSnCwUAwsKEE4oY=";

  meta = {
    homepage = "https://usage.jdx.dev";
    description = "A specification for CLIs";
    changelog = "https://github.com/jdx/usage/releases/tag/v${version}";
    mainProgram = "usage";
  };
}
