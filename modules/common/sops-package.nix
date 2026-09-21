{ inputs, lib, pkgs, ... }:

let
  installer = (pkgs.callPackage inputs.sops-nix.outPath { }).sops-install-secrets;
  go = pkgs.unstable.go_1_26;
in
{
  # WORKAROUND (2026-09-21): sops-nix requires Go 1.26; stable provides 1.25.
  # Affects: NixOS and Home Manager secret installation and manifest validation.
  # Upstream: https://github.com/Mic92/sops-nix/blob/master/go.mod
  # Check: Remove when the stable Go toolchain satisfies sops-nix's go.mod.
  sops.package = lib.mkDefault (installer.override {
    inherit go;
    buildGoModule = pkgs.buildGoModule.override { inherit go; };
  });
}
