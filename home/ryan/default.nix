{
  pkgs,
  lib,
  inputs,
  hostname,
  ...
}:
{
  imports = [
    ../_modules

    # ./secrets
    ./hosts/${hostname}.nix
  ];

  modules = {

    security = {
      ssh = {
        enable = true;
      };
    };

    shell = {
      fish.enable = true;

      git = {
        enable = true;
        username = "Ryan Holt";
        email = "ryan@ryanholt.net";
      };
    };

  };
}
