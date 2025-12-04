# Attic Admin Configuration
# This module provides admin token access for cache management
{ config, lib, ... }:

let
  cfg = config.modules.services.attic-admin;
in
{
  options.modules.services.attic-admin = {
    enable = lib.mkEnableOption "Attic admin client configuration";
  };

  config = lib.mkIf cfg.enable {
    # Override the basic attic config with admin token
    sops.templates."attic-admin-config" = {
      content = ''
        [default]
        default-server = "homelab"

        [servers.homelab]
        url = "https://attic.holthome.net/"
        token = "${config.sops.placeholder."attic/admin-token"}"
      '';
      path = "/etc/attic/config.toml";
      mode = "0644";
    };
  };
}
