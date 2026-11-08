{ inputs }:
# Forge as it was adopted: retired.nix switches Atrium off on the live host,
# and these checks keep testing the adopted configuration it would return to.
inputs.self.nixosConfigurations.forge.extendModules {
  # Evaluate with the inputs the caller passes (atriumInputs from flake.nix).
  specialArgs = { inherit inputs; };
  modules = [{
    disabledModules = [ ../../hosts/forge/atrium/retired.nix ];
  }];
}
