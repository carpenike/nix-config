#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B tests/finance-signal/test-runtime.py
nix eval --offline --impure --json --expr '
  let inputs = (builtins.getFlake (toString ./.)).inputs;
  in import ./tests/finance-signal/evaluate.nix { inherit inputs; }
'
