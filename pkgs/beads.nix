# Beads - Memory system and issue tracker for AI coding agents
# https://github.com/steveyegge/beads
#
# Source tracked by nvfetcher (pkgs/nvfetcher.toml)
# vendorHash must be updated manually when Go dependencies change
# To update: run `nix build .#beads` and use the hash from the error message
{ pkgs
, lib
, buildGoModule
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.beads;
in
buildGoModule rec {
  inherit (packageData) pname src;
  version = lib.strings.removePrefix "v" packageData.version;

  subPackages = [ "cmd/bd" ];
  doCheck = false;

  # vendorHash must be updated manually when Go dependencies change
  vendorHash = "sha256-BpACCjVk0V5oQ5YyZRv9wC/RfHw4iikc2yrejZzD1YU=";

  nativeBuildInputs = [ pkgs.git ];

  meta = with lib; {
    description = "beads (bd) - An issue tracker designed for AI-supervised coding workflows";
    homepage = "https://github.com/steveyegge/beads";
    license = licenses.mit;
    mainProgram = "bd";
    maintainers = [ ];
  };
}
