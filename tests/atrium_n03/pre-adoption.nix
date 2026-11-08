{ inputs }:
# Preparation checks exercise the module defaults, not the owner's opt-in.
# ./forge-retired re-adds the services that left Forge for the k8s cluster on
# 2026-11-08 (see ./forge-retired/default.nix).
inputs.self.nixosConfigurations.forge.extendModules {
  modules = [
    ./forge-retired
    {
      disabledModules = [
        ../../hosts/forge/atrium/adoption.nix
        ../../hosts/forge/atrium/retired.nix
      ];
      services.atriumPwa.enable = inputs.nixpkgs.lib.mkForce false;
    }
  ];
}
