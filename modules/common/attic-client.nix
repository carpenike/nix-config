# Attic Client Configuration
{ config, lib, pkgs, ... }:

{
  options.modules.binaryCache.attic = {
    pushToken = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SOPS secret path for the attic push token (e.g., 'attic/push-token')";
    };
  };

  config = {
    # Install attic-client on all systems
    environment.systemPackages = with pkgs; [
      attic-client
    ];

    # Basic attic client configuration for all hosts
    # If pushToken is set, use SOPS template; otherwise use static config
    environment.etc."attic/config.toml" = lib.mkIf (config.modules.binaryCache.attic.pushToken == null) (lib.mkMerge [
      {
        text = ''
          [default]
          default-server = "homelab"

          [servers.homelab]
          url = "https://attic.holthome.net/"
          # Read-only access - no token configured
        '';
      }
      # mode is only supported on NixOS, not nix-darwin
      (lib.mkIf pkgs.stdenv.isLinux {
        mode = "0644";
      })
    ]);
  };
}
