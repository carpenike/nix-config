# Binary Cache Configuration for Attic
{ config, lib, pkgs, ... }:

{
  imports = [
    ./attic-client.nix
  ];
  # Configure Nix to use the homelab binary cache
  nix.settings = {
    substituters = [
      "https://attic.holthome.net/homelab"  # Our Linux cache
    ] ++ lib.optionals pkgs.stdenv.isDarwin [
      "https://attic.holthome.net/homelab-darwin"  # Our Darwin cache
    ] ++ [
      "https://cache.nixos.org"            # Upstream cache
    ];

    trusted-public-keys = [
      "homelab:dvj/fuq/zDqPuSkvQeQBj1OB36nh725SZHXXfRQHp+U="  # Homelab cache
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="  # Upstream
    ];

    # Fallback when substituters are unavailable
    fallback = true;

    # Connect timeout for cache requests
    connect-timeout = 5;

    # Enable extra logging for cache debugging
    log-lines = lib.mkDefault 25;
  };

  # Make attic-client available on all systems
  environment.systemPackages = with pkgs; [
    attic-client
  ];
}
