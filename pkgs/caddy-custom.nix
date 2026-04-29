# Custom Caddy build with plugins
#
# This package builds Caddy with additional plugins compiled in.
# When Renovate updates plugin versions, the hash will need to be updated.
#
# To get the correct hash after a version bump:
# 1. Set hash to lib.fakeHash (or an empty string)
# 2. Run: nix build .#caddy   (or push the change and read the CI failure)
# 3. Copy the expected hash from the error message into the `hash` field
#
{ pkgs, lib ? pkgs.lib }:

pkgs.caddy.withPlugins {
  plugins = [
    # renovate: depName=github.com/caddy-dns/cloudflare datasource=go
    "github.com/caddy-dns/cloudflare@v0.2.4"
    # renovate: depName=github.com/greenpau/caddy-security datasource=go
    "github.com/greenpau/caddy-security@v1.1.62"
  ];
  # WORKAROUND (2025-01-01): Hash updated after plugin version changes.
  # Updated 2026-04-29: combined bump of caddy-security v1.1.31 → v1.1.62
  # AND caddy-dns/cloudflare v0.2.3 → v0.2.4 (the v0.2.4 part already
  # landed via PR #376). Hash captured from CI fakeHash probe on this PR.
  hash = "sha256-eacR0fi+m/l5zRu4griQ0YTRnT8UdflKgzXaZ6Eh5+k=";
}
