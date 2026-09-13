{ config, inputs, pkgs, lib, mylib }:
let
  registry = import ./registry.nix {
    inherit lib;
    homelabMcp = inputs.homelab-mcp;
    cloudInventory = config.modules.services.litellm.models;
  };
  runtime = import ./runtime.nix {
    inherit lib;
    adoption = config.services.atriumForge.adoption;
    modelSettings = models.resolver;
  };
  models = import ./models.nix {
    inherit lib runtime registry;
    ids = mylib.serviceUids;
  };
in
{
  inherit registry runtime models;
  bootstrap = import ./bootstrap.nix { inherit lib registry; };
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
}
