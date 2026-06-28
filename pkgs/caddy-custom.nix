# Caddy with plugins (via the supported `caddy.withPlugins` API)
#
# This is NOT a workaround. caddy-dns/cloudflare and caddy-security are
# external Caddy modules that stock Caddy will never bundle, so a build that
# compiles them in is always required. nixpkgs (25.05+) provides the
# first-class `caddy.withPlugins` mechanism used below, so no hand-rolled
# xcaddy / buildGoModule is needed.
#
# Ongoing maintenance: `withPlugins` vendors the Go modules as a fixed-output
# derivation, so the `hash` must be re-pinned whenever plugin versions OR the
# nixpkgs caddy version change.
#
# To get the correct hash after a bump:
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
  # Hash re-pin log (re-pinning is expected with withPlugins; see header note):
  # Updated 2026-04-29: combined bump of caddy-security v1.1.31 → v1.1.62
  # AND caddy-dns/cloudflare v0.2.3 → v0.2.4 (the v0.2.4 part already
  # landed via PR #376). Hash captured from CI fakeHash probe on this PR.
  # Updated 2026-05-17: hash drifted again after flake.lock bump #450
  # (nixpkgs update changed how caddy.withPlugins resolves go module
  # vendoring). Plugin versions unchanged. Hash captured from forge apply.
  # Updated 2026-05-26: hash drifted again after another nixpkgs bump
  # (plugin versions unchanged). Hash captured from forge build failure.
  # Updated 2026-06-27: hash drifted again after a nixpkgs bump
  # (plugin versions unchanged). Hash captured from forge build failure.
  hash = "sha256-blINVJ6vakiRtsQHIyp+NrhTiyyS4jjwBXVcaWqJAJo=";
}
