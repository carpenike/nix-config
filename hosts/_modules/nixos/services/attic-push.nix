# Attic Auto-Push Configuration
# This module configures automatic pushing of build outputs to the Attic binary cache
# using Nix's post-build-hook mechanism.
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.attic-push;

  # Script to push built paths to Attic
  pushScript = pkgs.writeShellScript "attic-post-build-hook" ''
    set -uf

    # Only push if we have paths to push
    if [[ -z "''${OUT_PATHS:-}" ]]; then
      exit 0
    fi

    # Log what we're doing
    echo "Pushing paths to Attic cache: $OUT_PATHS"

    # Push the paths to the cache
    # Exit 0 regardless of success to avoid failing builds if cache is temporarily unavailable
    ${pkgs.attic-client}/bin/attic push ${cfg.cacheName} $OUT_PATHS || {
      echo "Warning: Failed to push to Attic cache (exit code $?), continuing anyway"
      exit 0
    }
  '';
in
{
  options.modules.services.attic-push = {
    enable = lib.mkEnableOption "Automatic pushing of builds to Attic cache";

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "homelab";
      description = "Name of the Attic cache to push to";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing the Attic authentication token";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "attic-push requires tokenFile to be set for authentication";
      }
    ];

    # Configure the Attic client with the push token
    sops.templates."attic-push-config" = {
      content = ''
        [default]
        default-server = "homelab"

        [servers.homelab]
        endpoint = "https://attic.holthome.net/"
        token = "${config.sops.placeholder."attic/push-token"}"
      '';
      # Put this in root's config since post-build-hook runs as root
      path = "/root/.config/attic/config.toml";
      mode = "0600";
      owner = "root";
      group = "root";
    };

    # Configure Nix to use the post-build hook
    nix.settings = {
      # The post-build-hook runs after each successful build
      post-build-hook = pushScript;

      # Ensure we're a trusted user (required for post-build-hook)
      trusted-users = [ "root" "@wheel" ];
    };

    # Make attic-client available system-wide
    environment.systemPackages = [ pkgs.attic-client ];
  };
}
