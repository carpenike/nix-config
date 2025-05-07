{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-nix" ''
      #!/usr/bin/env bash
      set -euo pipefail

      echo "📦 Updating system from remote flake..."

      sudo nixos-rebuild switch \
        --flake github:carpenike/nix-config#luna \
        --option accept-flake-config true \
        --refresh \
        --show-trace
    '')

    (pkgs.writeShellScriptBin "check-config-match" ''
      #!/usr/bin/env bash
      set -e # Exit immediately if a command exits with a non-zero status.

      # --- Configuration ---
      REMOTE_REPO_URL="https://github.com/carpenike/nix-config"
      BRANCH_NAME="main" # Or your default branch
      FLAKE_OUTPUT_NAME="luna" # The name of the nixosConfiguration output in your flake
      # --- End Configuration ---

      echo "🔍 Getting current system path..."
      current_system=$(readlink /run/current-system)
      if [ -z "$current_system" ]; then
        echo "Error: Could not read /run/current-system symlink."
        exit 1
      fi
      echo "   Current system: $current_system"

      echo "🔄 Fetching latest commit SHA from remote '$REMOTE_REPO_URL' branch '$BRANCH_NAME'..."
      remote_commit_sha=$(${pkgs.git}/bin/git ls-remote "$REMOTE_REPO_URL" "refs/heads/$BRANCH_NAME" | ${pkgs.gawk}/bin/awk '{print $1}')
      if [ -z "$remote_commit_sha" ]; then
        echo "Error: Failed to get commit SHA from remote '$REMOTE_REPO_URL' for branch '$BRANCH_NAME'."
        exit 1
      fi
      echo "   Latest remote commit ($BRANCH_NAME): $remote_commit_sha"

      echo "🛠️ Determining store path for the remote configuration..."
      # Construct the full flake output path for the NixOS system derivation
      flake_output_path="nixosConfigurations.''${FLAKE_OUTPUT_NAME}.config.system.build.toplevel"
      # Escape $ for Nix string interpolation
      flake_uri="github:carpenike/rv-nixpi/''${remote_commit_sha}#''${flake_output_path}"
      echo "   Building derivation from: $flake_uri"

      # Use nix build --print-out-paths to get the store path without creating a result link
      # Need to accept the flake config potentially and enable experimental features
      # Redirect stderr to /dev/null to hide build output on success
      remote_system=$(${pkgs.nix}/bin/nix build \
        --extra-experimental-features 'nix-command flakes' \
        --print-out-paths \
        "$flake_uri" \
        --option accept-flake-config true 2>/dev/null)

      if [ $? -ne 0 ] || [ -z "$remote_system" ]; then
        echo "❌ Error: Failed to build the derivation for the remote configuration."
        echo "   Please check:"
        echo "     1. The FLAKE_OUTPUT_NAME ('$FLAKE_OUTPUT_NAME') is correct in this script."
        echo "     2. The configuration for commit $remote_commit_sha builds successfully."
        echo "     3. Network connectivity allows fetching the flake."
        exit 1
      fi
      # Take the first line in case nix build outputs multiple paths
      remote_system=$(echo "$remote_system" | head -n 1)
      echo "   Remote system build path: $remote_system"

      echo "⚖️ Comparing paths..."
      # Escape $ for Nix string interpolation
      if [ "$current_system" = "$remote_system" ]; then
        echo "✅ Match! The current system configuration matches the latest commit ($remote_commit_sha) on ''${BRANCH_NAME}."
        exit 0
      else
        echo "❌ Mismatch! The current system configuration does not match the latest commit ($remote_commit_sha) on ''${BRANCH_NAME}."
        echo "   Current: $current_system"
        echo "   Remote:  $remote_system"
        echo "   Consider running 'update-nix'."
        exit 1 # Exit with non-zero status to indicate mismatch
      fi
    '')

    # (pkgs.writeShellScriptBin "rvc-dbc-test" ''
    #   #!/usr/bin/env bash
    #   set -euo pipefail
    #
    #   INTERFACE=''${1:-can0}
    #   DBC_PATH="/etc/nixos/files/generated_rvc.dbc"
    #   SCRIPT="/etc/nixos/files/live_can_decoder.py"
    #
    #   if [ ! -f "$DBC_PATH" ]; then
    #     echo "❌ DBC file not found at $DBC_PATH"
    #     exit 1
    #   fi
    #
    #   if [ ! -f "$SCRIPT" ]; then
    #     echo "❌ Python script not found at $SCRIPT"
    #     exit 1
    #   fi
    #
    #   echo "▶️ Running decoder on interface $INTERFACE"
    #   python3 "$SCRIPT" --interface "$INTERFACE" --dbc "$DBC_PATH"
    # '')
  ];
}
