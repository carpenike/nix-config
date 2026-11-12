# The mail relay is a server: shell and git only, no development
# toolchains. It also runs a newer NixOS than the fleet (26.05), which no
# longer has some packages the language modules name (nodePackages), and
# Hydra does not cache its Python 3.11 set, which the backup tools use.
# Nothing on this host is backed up by them.
{ lib, ... }:
{
  modules.utilities.backupTools.enable = false;
  modules.development = {
    enable = lib.mkForce false;
    languages = {
      python.enable = false;
      nodejs.enable = false;
      go.enable = false;
      rust.enable = false;
    };
  };
}
