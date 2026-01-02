# Shared Service Groups Module
#
# Defines centralized groups used by multiple services for file sharing.
# This ensures consistent GID allocation across all media services.
#
# Usage:
#   1. Enable this module on hosts that run arr stack or media services
#   2. Services reference groups by name: `group = "media"`
#   3. The module ensures the group exists with the correct GID
#
{ config, lib, ... }:

let
  cfg = config.modules.users.sharedGroups;

  # Media group GID - matches lib/service-uids.nix mediaGroup.gid
  # Intentionally high to avoid conflicts with system groups
  mediaGroupGid = 65537;
in
{
  options.modules.users.sharedGroups = {
    enable = lib.mkEnableOption "shared service groups (media, etc.)";

    media = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create the shared 'media' group for arr stack and media services";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = mediaGroupGid;
        description = "GID for the media group (should match lib/service-uids.nix)";
      };

      members = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional users to add to the media group";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Define the shared media group
    users.groups = lib.mkIf cfg.media.enable {
      media = {
        gid = cfg.media.gid;
        members = cfg.media.members;
      };
    };
  };
}
