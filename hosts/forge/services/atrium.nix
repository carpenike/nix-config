{ inputs, pkgs, ... }:
let
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  imports = [ inputs.atrium.nixosModules.atrium ];

  environment.systemPackages = [
    packages.resolver
    packages.atrium-litellm-controller
  ];

  # Package installation does not bootstrap identity, publish policy, or start units.
  services.atrium.runtime = {
    resolver.package = packages.resolver;
    reconciler = {
      package = packages.atrium-litellm-controller;
      executable = "atrium-litellm-controller";
    };
  };
}
