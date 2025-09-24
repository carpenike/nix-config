{ config, pkgs, hostname, lib, ... }:
{
  environment.systemPackages = [
    # Universal update script that uses the current hostname
    (pkgs.writeShellScriptBin "update-nix" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Error recovery guidance
      cleanup() {
        if [ $? -ne 0 ]; then
          echo ""
          echo "❌ Update failed!"
          echo ""
          echo "Recovery options:"
          echo "  1. Fix the issue and try again"
          echo "  2. Roll back to previous generation:"
          if [[ "$(uname)" == "Darwin" ]]; then
            echo "     darwin-rebuild switch --rollback"
          else
            echo "     sudo nixos-rebuild switch --rollback"
          fi
        fi
      }
      trap cleanup EXIT

      # Parse arguments
      FLAKE_URI=""
      BUILD_ONLY=false
      SHOW_DIFF=true

      while [[ $# -gt 0 ]]; do
        case $1 in
          --build-only)
            BUILD_ONLY=true
            shift
            ;;
          --no-diff)
            SHOW_DIFF=false
            shift
            ;;
          *)
            FLAKE_URI="$1"
            shift
            ;;
        esac
      done

      # Default to GitHub if no flake URI provided
      FLAKE_URI="''${FLAKE_URI:-github:carpenike/nix-config}"

      echo "📦 Updating ${hostname} from flake: $FLAKE_URI"
      echo ""

      # Check network connectivity if using remote flake
      if [[ "$FLAKE_URI" == github:* ]] || [[ "$FLAKE_URI" == http* ]]; then
        echo "🌐 Checking network connectivity..."
        if ! ${pkgs.curl}/bin/curl -s --connect-timeout 5 https://github.com > /dev/null 2>&1; then
          echo "❌ No network connectivity. Cannot fetch remote flake."
          echo "   Try using a local flake path instead."
          exit 1
        fi
      fi

      # Determine commands based on OS
      if [[ "$(uname)" == "Darwin" ]]; then
        BUILD_CMD="darwin-rebuild build"
        SWITCH_CMD="darwin-rebuild switch"
        CURRENT_SYSTEM="/run/current-system"
      else
        BUILD_CMD="nixos-rebuild build"
        SWITCH_CMD="env HOME=/root doas nixos-rebuild switch"
        CURRENT_SYSTEM="/run/current-system"
      fi

      # Step 1: Build only
      echo "🔨 Building new configuration..."
      echo "   This may take a while..."
      echo ""

      if ! $BUILD_CMD \
        --flake "$FLAKE_URI#${hostname}" \
        --option accept-flake-config true \
        --refresh \
        --show-trace; then
        echo ""
        echo "❌ Build failed! Check the errors above."
        exit 1
      fi

      echo ""
      echo "✅ Build successful!"

      # Step 2: Show diff if nvd is available and not disabled
      if [[ "$SHOW_DIFF" == "true" ]] && command -v nvd &> /dev/null; then
        echo ""
        echo "📊 Changes in this update:"
        echo ""
        nvd diff "$CURRENT_SYSTEM" ./result || true
        echo ""
      fi

      # If build-only, stop here
      if [[ "$BUILD_ONLY" == "true" ]]; then
        echo "🏁 Build complete (--build-only specified)"
        echo "   Result is available at: ./result"
        exit 0
      fi

      # Step 3: Ask for confirmation
      echo "🚀 Ready to apply the new configuration"
      read -p "   Continue? (y/N) " -n 1 -r
      echo ""

      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Aborted by user"
        exit 0
      fi

      # Step 4: Switch
      echo ""
      echo "⚙️  Applying new configuration..."
      $SWITCH_CMD --flake "$FLAKE_URI#${hostname}"

      echo ""
      echo "✅ Update complete!"
      echo ""
      echo "💡 Current generation: $(${if pkgs.stdenv.isDarwin then "darwin-rebuild" else "nixos-rebuild"} list-generations | tail -n 1)"
    '')
  ];
}
