{ inputs }:
# Preparation checks exercise the module defaults, not the owner's opt-in.
inputs.self.nixosConfigurations.forge.extendModules {
  modules = [{
    disabledModules = [ ../../hosts/forge/atrium/adoption.nix ];
  }];
}
