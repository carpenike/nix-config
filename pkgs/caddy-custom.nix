# Custom Caddy build with plugins
#
# This package builds Caddy with additional plugins compiled in.
# When Renovate updates plugin versions, the hash will need to be updated.
#
# To get the correct hash after a version bump:
# 1. Set hash to an empty string or lib.fakeHash
# 2. Run: nix build .#caddy
# 3. Copy the expected hash from the error message
#
{ pkgs }:

pkgs.caddy.withPlugins {
  plugins = [
    # renovate: depName=github.com/caddy-dns/cloudflare datasource=go
    "github.com/caddy-dns/cloudflare@v0.2.3"
    # renovate: depName=github.com/greenpau/caddy-security datasource=go
    "github.com/greenpau/caddy-security@v1.1.31"
  ];
  # WORKAROUND (2025-01-01): Hash updated after plugin version changes
  # Run `nix build .#caddy` with lib.fakeHash to get new hash when plugins update
  # Updated 2026-04-28 (2nd time): the source bundle drifted again after the
  # 14:17 UTC `update-flake-lock` workflow bumped nixpkgs, which shifted
  # caddy's Go vendor closure. Plugin versions and caddy version are still
  # identical — the only thing that changed is the upstream packaging.
  # Long-term: switch to a hash-less builder or accept that every nixpkgs
  # bump that touches the caddy package will require a hash refresh here.
  hash = "sha256-3c0AYH1OJvciUfi+xY2ULzIK4fn4+CEyF7ZncZoJm3c=";
}
