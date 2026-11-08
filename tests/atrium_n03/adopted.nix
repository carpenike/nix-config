{ inputs }:
# Forge as it was adopted: retired.nix switches Atrium off on the live host,
# and these checks keep testing the adopted configuration it would return to.
inputs.self.nixosConfigurations.forge.extendModules {
  modules = [{
    disabledModules = [ ../../hosts/forge/atrium/retired.nix ];
  }];
}
