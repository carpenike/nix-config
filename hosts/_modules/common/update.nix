{ config, pkgs, hostname, lib, ... }:
{
  environment.systemPackages = [
    # Universal update script that uses the current hostname
    (pkgs.writeShellScriptBin "update-nix" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Error recovery guidance - preserve exit code
      EXIT_CODE=0
      cleanup() {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          echo ""
          echo "❌ Update failed!"
          echo ""
          echo "Recovery options:"
          echo "  1. Fix the issue and try again"
          echo "  2. Roll back to previous generation:"
          if [[ "$(uname)" == "Darwin" ]]; then
            echo "     darwin-rebuild switch --rollback"
          else
            # Use dynamic privilege escalation
            if command -v doas >/dev/null 2>&1; then
              echo "     doas nixos-rebuild switch --rollback"
            elif command -v sudo >/dev/null 2>&1; then
              echo "     sudo nixos-rebuild switch --rollback"
            else
              echo "     nixos-rebuild switch --rollback"
            fi
          fi
        fi
        exit $exit_code
      }
      trap cleanup EXIT

      # Parse arguments
      FLAKE_URI=""
      BUILD_ONLY=false
      DRY_RUN=false
      SHOW_DIFF=true
      BUILD_TIMEOUT=1800  # 30 minutes

      while [[ $# -gt 0 ]]; do
        case $1 in
          --build-only)
            BUILD_ONLY=true
            shift
            ;;
          --dry-run)
            DRY_RUN=true
            BUILD_ONLY=true  # Dry run implies build-only
            shift
            ;;
          --no-diff)
            SHOW_DIFF=false
            shift
            ;;
          --timeout)
            BUILD_TIMEOUT="$2"
            shift 2
            ;;
          *)
            FLAKE_URI="$1"
            shift
            ;;
        esac
      done

      # Default to GitHub if no flake URI provided
      FLAKE_URI="''${FLAKE_URI:-github:carpenike/nix-config}"

      # Set hostname from Nix build-time parameter
      HOSTNAME="${hostname}"

      # Validate hostname for shell injection protection
      if [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "❌ Invalid hostname: $HOSTNAME"
        echo "   Hostname must contain only alphanumeric characters, dots, hyphens, and underscores"
        exit 1
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔍 DRY RUN: Updating $HOSTNAME from flake: $FLAKE_URI"
        echo "   (No changes will be applied)"
      else
        echo "📦 Updating $HOSTNAME from flake: $FLAKE_URI"
      fi
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

      # Determine commands based on OS with dynamic privilege escalation
      if [[ "$(uname)" == "Darwin" ]]; then
        BUILD_CMD="darwin-rebuild build"
        SWITCH_CMD="darwin-rebuild switch"
        CURRENT_SYSTEM="/run/current-system"
      else
        # For NixOS, detect available privilege escalation tool
        if command -v doas >/dev/null 2>&1; then
          PRIV_CMD="doas"
        elif command -v sudo >/dev/null 2>&1; then
          PRIV_CMD="sudo"
        else
          echo "⚠️  Warning: No privilege escalation tool found (doas/sudo)"
          echo "   Attempting to run as current user..."
          PRIV_CMD=""
        fi

        BUILD_CMD="$PRIV_CMD nixos-rebuild build"
        SWITCH_CMD="$PRIV_CMD nixos-rebuild switch"
        CURRENT_SYSTEM="/run/current-system"
      fi

      # Step 1: Build only
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔍 DRY RUN: Would build configuration with:"
        echo "   Command: $BUILD_CMD --flake \"$FLAKE_URI#$HOSTNAME\" --option accept-flake-config true --refresh --show-trace"
        echo "   Timeout: $BUILD_TIMEOUT"s
        echo ""
        echo "✅ Dry run complete - no actual build performed"
        exit 0
      fi

      echo "🔨 Building new configuration..."
      echo "   This may take a while (timeout: $BUILD_TIMEOUT"s")..."
      echo ""

      if ! timeout "$BUILD_TIMEOUT" $BUILD_CMD \
        --flake "$FLAKE_URI#$HOSTNAME" \
        --option accept-flake-config true \
        --refresh \
        --show-trace; then
        echo ""
        if [ $? -eq 124 ]; then
          echo "❌ Build timed out after $BUILD_TIMEOUT seconds!"
          echo "   Try increasing timeout with --timeout <seconds> or check for hanging processes"
        else
          echo "❌ Build failed! Check the errors above."
        fi
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
      $SWITCH_CMD --flake "$FLAKE_URI#$HOSTNAME"

      echo ""
      echo "✅ Update complete!"
      echo ""
      echo "💡 Current generation: $(${if pkgs.stdenv.isDarwin then "darwin-rebuild" else "nixos-rebuild"} list-generations | tail -n 1)"
    '')
  ];
}
