{ inputs }:
# Forge as it was adopted: retired.nix switches Atrium off on the live host,
# and these checks keep testing the adopted configuration it would return to.
# The services Atrium wrapped left Forge for the k8s cluster on 2026-11-08, so
# ./forge-retired adds back the frozen definitions the adopted host needs.
inputs.self.nixosConfigurations.forge.extendModules {
  modules = [
    ./forge-retired
    {
      disabledModules = [ ../../hosts/forge/atrium/retired.nix ];
    }
  ];
}
