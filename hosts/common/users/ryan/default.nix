{ pkgs, inputs, config, lib, configVars, configLib, ... }:
let
  ifTheyExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  # isMinimal is typically true during nixos-installer boostrapping (see /nixos-installer/flake.nix) and for
  # iso where we want to limit the depth of user configuration
  # FIXME  this should just pass an isIso style thing that we can check instead
  config = lib.optionalAttrs (!(lib.hasAttr "isMinimal" configVars))
  {
    # Import this user's personal/home configurations
#??     packages = [ pkgs.home-manager ];
    home-manager.users.${configVars.username} = import (configLib.relativeToRoot "home/${configVars.username}/${config.networking.hostName}.nix");
  } // {
    users.mutableUsers = false; # Required for password to be set via sops during system activation!
    users.users.${configVars.username} = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
      ] ++ ifTheyExist [
        "audio"
        "video"
        "docker"
        "git"
        "networkmanager"
      ];

      openssh.authorizedKeys.keys = [ "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOslNYCKlAhgO9vxUVt4Vq0diz35JD0f6Vtdh2zfZwyb+SI/TPC+U06TPsxS++KN+HHkQvNBcqpQ6a8qNsYsVJA="];

      shell = pkgs.fish; # default shell

    };

    # No matter what environment we are in we want these tools for root, and the user(s)
    programs.fish.enable = true;
    programs.git.enable = true;
    environment.systemPackages = [
      pkgs.rsync
    ];
  };
}
