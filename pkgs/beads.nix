# Beads - Memory system and issue tracker for AI coding agents
# https://github.com/steveyegge/beads
#
# Source tracked by nvfetcher (pkgs/nvfetcher.toml)
# vendorHash must be updated manually when Go dependencies change.
# To update vendorHash: set it to lib.fakeHash, run `nix build .#beads`,
# copy the expected hash from the error message into vendorHash.
{ pkgs
, lib
, ...
}:
let
  sourceData = pkgs.callPackage ./_sources/generated.nix { };
  packageData = sourceData.beads;

  # WORKAROUND (2026-04-29): beads >= 1.0 requires Go >= 1.26.2 in its
  # go.mod, but nixpkgs default `go` is still 1.25.x. Use go_1_26 explicitly
  # so the build doesn't fail with `go: go.mod requires go >= 1.26.2`.
  # Remove this override when nixpkgs' default `go` reaches 1.26.
  buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_26; };
in
buildGoModule rec {
  inherit (packageData) pname src;
  version = lib.strings.removePrefix "v" packageData.version;

  subPackages = [ "cmd/bd" ];
  doCheck = false;

  # vendorHash must be updated manually when Go dependencies change.
  # Set to lib.fakeHash temporarily — CI on this PR will print the
  # expected value, which we then commit. (Refresh after every nvfetcher
  # bump that produces a different go.sum.)
  vendorHash = lib.fakeHash;

  nativeBuildInputs = [ pkgs.git pkgs.pkg-config ];
  buildInputs = [ pkgs.icu ];

  meta = with lib; {
    description = "beads (bd) - An issue tracker designed for AI-supervised coding workflows";
    homepage = "https://github.com/steveyegge/beads";
    license = licenses.mit;
    mainProgram = "bd";
    maintainers = [ ];
  };
}
