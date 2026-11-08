{ inputs }:
# Preparation checks exercise the module defaults, not the owner's opt-in.
inputs.self.nixosConfigurations.forge.extendModules {
  # Evaluate with the inputs the caller passes (atriumInputs from flake.nix).
  specialArgs = { inherit inputs; };
  modules = [{
    disabledModules = [
      ../../hosts/forge/atrium/adoption.nix
      ../../hosts/forge/atrium/retired.nix
    ];
    services.atriumPwa.enable = inputs.nixpkgs.lib.mkForce false;
  }];
}
