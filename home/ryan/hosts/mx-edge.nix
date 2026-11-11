# The mail relay is a server: shell and git only, no development
# toolchains. It also runs a newer NixOS than the fleet (26.05), which no
# longer has some packages the language modules name (nodePackages).
{ lib, ... }:
{
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
