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
    "github.com/greenpau/caddy-security@v1.1.62"
  ];
  # WORKAROUND (2025-01-01): Hash updated after plugin version changes
  # Run `nix build .#caddy` with lib.fakeHash to get new hash when plugins update
  # Updated 2026-04-29: bumped greenpau/caddy-security v1.1.31 → v1.1.62
  # (large gap because Renovate had been blocked by CI for ~2 months).
  # Hash taken from the CI failure output on this PR.
  hash = "sha256-iyJz2ZX7QNrSVh+hgG3pak2+R17GRrbdRqVaMKbopSI=";
}
