#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
nix eval --offline --no-write-lock-file --impure --json --expr '
  let inputs = (builtins.getFlake (toString ./.)).inputs;
  in import ./tests/finance-signal-production/evaluate.nix { inherit inputs; }
'
# Nix, not the shell, expands the attribute-selection expressions below.
# shellcheck disable=SC2016
nix build --offline --no-write-lock-file --no-link --impure --print-build-logs --expr '
  let
    inputs = (builtins.getFlake (toString ./.)).inputs;
    pkgs = inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  in import ./tests/finance-signal-production/check.nix {
    inherit pkgs;
    package = inputs.homelab-mcp.packages.${builtins.currentSystem}.default;
    source = inputs.homelab-mcp;
  }
'
