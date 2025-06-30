{ config, pkgs, hostname, ... }:
{
  environment.systemPackages = [
    # Universal update script that uses the current hostname
    (pkgs.writeShellScriptBin "update-nix" ''
      #!/usr/bin/env bash
      set -euo pipefail

      echo "📦 Updating ${hostname} from remote flake..."

      # Determine the appropriate rebuild command based on the system
      if [[ "$(uname)" == "Darwin" ]]; then
        # macOS system
        darwin-rebuild switch \
          --flake "github:carpenike/nix-config#${hostname}" \
          --option accept-flake-config true \
          --refresh \
          --show-trace
      else
        # NixOS system
        sudo nixos-rebuild switch \
          --flake "github:carpenike/nix-config#${hostname}" \
          --option accept-flake-config true \
          --refresh \
          --show-trace
      fi
    '')
  ];
}
