{ pkgs, ... }:
{
  environment.systemPackages = [
    # Custom update script for nixpi
    (pkgs.writeShellScriptBin "update-nixpi" ''
      #!/usr/bin/env bash
      set -euo pipefail

      echo "📦 Updating nixpi from remote flake..."

      sudo nixos-rebuild switch \
        --flake github:carpenike/nix-config#nixpi \
        --option accept-flake-config true \
        --refresh \
        --show-trace
    '')
  ];

  # Note: Package organization follows repository patterns:
  # - User packages: Moved to home/ryan/hosts/nixpi.nix
  # - Hardware packages: Handled by hardware modules
  #   - can-utils → pican2-duo.nix
  #   - i2c-tools → pican2-duo.nix
  #   - libraspberrypi, raspberrypi-eeprom → raspberry-pi.nix
  # - Common utilities (vim, git, curl, wget): Already in home/_modules/shell/
  # - Python packages: In home/ryan/hosts/nixpi.nix for RVC development
}
