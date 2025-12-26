# Binary Cache Configuration for Attic
{ config, lib, pkgs, ... }:

{
  imports = [
    ./attic-client.nix
  ];

  options.modules.binaryCache = {
    attic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false; # Disabled by default - attic cache not currently functional
      description = "Whether to use the Attic binary cache (attic.holthome.net)";
    };
  };

  # Configure Nix to use the homelab binary cache
  config.nix.settings = {
    substituters = lib.optionals config.modules.binaryCache.attic.enable
      ([
        "https://attic.holthome.net/homelab" # Our Linux cache
      ] ++ lib.optionals pkgs.stdenv.isDarwin [
        "https://attic.holthome.net/homelab-darwin" # Our Darwin cache
      ]) ++ [
      "https://cache.nixos.org" # Upstream cache
    ];

    trusted-public-keys = lib.optionals config.modules.binaryCache.attic.enable ([
      "homelab:92CMbbyYFZhtH/uOj2mv/SfAcNfRJJqV/gcuBFpRWpk=" # Homelab cache (nas-1)
    ] ++ lib.optionals pkgs.stdenv.isDarwin [
      "homelab-darwin:UmQUnjJJ8EBx0BA55x1J9VELI5FfHUtYhlqVmdL/bV4=" # Darwin cache (nas-1)
    ]) ++ [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" # Upstream
    ];

    # Fallback when substituters are unavailable
    fallback = true;

    # Connect timeout for cache requests
    connect-timeout = 5;

    # Enable extra logging for cache debugging
    log-lines = lib.mkDefault 25;
  };

  # Make attic-client available on all systems
  config.environment.systemPackages = with pkgs; [
    attic-client
  ];
}
