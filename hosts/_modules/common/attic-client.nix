# Attic Client Configuration
{ config, lib, pkgs, ... }:

{
  # Install attic-client on all systems
  environment.systemPackages = with pkgs; [
    attic-client
  ];

  # Basic attic client configuration for all hosts (read-only access to public cache)
  environment.etc."attic/config.toml" = {
    text = ''
      [default]
      default-server = "homelab"

      [servers.homelab]
      url = "https://attic.holthome.net/"
      # Public cache - no token needed for read access
    '';
    mode = "0644";
  };
}
