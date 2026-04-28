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
  # Updated 2026-04-28: nixpkgs caddy.withPlugins source bundle drift (same plugin
  # versions, but the underlying derivation now produces a different vendor hash).
  hash = "sha256-KvAIO5JR7LDGvgZvl5E1GFts0ux1qEu/0u66r1zAjls=";
}
