{ inputs, pkgs, lib, ... }:
let
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
  identity = import ../atrium/identity.nix { inherit lib; };
in
{
  imports = [ inputs.atrium.nixosModules.atrium ];

  environment.systemPackages = [
    packages.resolver
    packages.atrium-litellm-controller
  ];

  environment.etc = {
    "atrium/bootstrap/identity.json".source = ../atrium/identity-bootstrap.json;
    "atrium/bootstrap/resolver.json".text = builtins.toJSON identity.settings;
  };

  services.atrium.litellmVersion = "v1.100.1";

  # Package installation does not bootstrap identity, publish policy, or start units.
  services.atrium.runtime = {
    resolver.package = packages.resolver;
    reconciler = {
      package = packages.atrium-litellm-controller;
      executable = "atrium-litellm-controller";
    };
  };
}
