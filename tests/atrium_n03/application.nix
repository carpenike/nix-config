{ inputs }:
let
  app = inputs.atrium;
  pin = (builtins.fromJSON (builtins.readFile ./pins.json)).atrium;
  packageNames = [ "atrium-litellm-controller" "atrium-litellm-admission" ];
  available = app.rev == pin
    && inputs.nixpkgs.lib.all
    (system: inputs.nixpkgs.lib.all
      (name: builtins.hasAttr name app.packages.${system})
      packageNames)
    [ "x86_64-linux" "aarch64-linux" ]
    && app.nixosModules ? litellm-admission;
in
assert inputs.nixpkgs.lib.assertMsg available "N03 requires the selected app package and module exports.";
{
  inherit available packageNames;
  revision = pin;
  repository = "carpenike/atrium";
  scope = "deployment package selection only; app preflight owns canonical source/evidence qualification";
}
