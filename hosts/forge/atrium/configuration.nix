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
    groupEvidence = config.services.atriumForge.groupEvidence;
    browserOrigin = if config.services.atriumPwa.enable then config.services.atriumPwa.origin else null;
    modelSettings = models.resolver;
  };
  models = import ./models.nix {
    inherit lib runtime registry;
    ids = mylib.serviceUids;
  };
  bootstrap = import ./bootstrap.nix { inherit lib registry; };
  setup = import ./setup.nix {
    inherit lib registry bootstrap runtime models;
    host = config.networking.hostName;
    domain = config.networking.domain;
    sshUser = config.users.users.ryan.name;
  };
in
{
  inherit registry runtime models bootstrap setup;
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
}
