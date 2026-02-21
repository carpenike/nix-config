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
  cargoHash = "sha256-ccAPI50X13b15do3dwfmMKxRfIZuFl5+BO/2Hh9zNyA=";

  # WORKAROUND (2025-02-11): 4 tests fail in complete_word test suite
  # Affects: usage-cli v2.16.1
  # Upstream: https://github.com/jdx/usage/issues (upstream test failures)
  # Check: Re-enable on next version bump
  doCheck = false;

  meta = {
    homepage = "https://usage.jdx.dev";
    description = "A specification for CLIs";
    changelog = "https://github.com/jdx/usage/releases/tag/v${version}";
    mainProgram = "usage";
  };
}
