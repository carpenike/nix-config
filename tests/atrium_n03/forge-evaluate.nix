{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  packages = inputs.atrium.packages.${c.nixpkgs.hostPlatform.system};
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  identity = import ../../hosts/forge/atrium/identity.nix { inherit lib; };
  gateway = builtins.fromJSON (builtins.readFile
    (inputs.atrium + "/harness/version-candidates/litellm-1.100.1.json"));
  gatewayDocuments = inputs.atrium.lib.renderForGateway {
    registry = import ../atrium/registry.nix { atrium = inputs.atrium; };
    nativeVersion = c.services.atrium.litellmVersion;
  };
  checks = {
    accepted-application-pin = inputs.atrium.rev == pins.atrium;
    explicit-gateway-version =
      gateway.kind == "atrium.litellm-version-candidate"
      && gateway.native_version == "v1.100.1"
      && c.services.atrium.litellmVersion == gateway.native_version;
    qualified-gateway-image = c.modules.services.litellm.image
      == builtins.replaceStrings [ "@" ] [ ":${gateway.native_version}@" ] gateway.image;
    version-aware-desired-state =
      gatewayDocuments.litellm.native_version == c.services.atrium.litellmVersion;
    resolver-installed = lib.elem packages.resolver c.environment.systemPackages;
    controller-installed = lib.elem packages.atrium-litellm-controller c.environment.systemPackages;
    actual-component-packages =
      c.services.atrium.runtime.resolver.package == packages.resolver
      && c.services.atrium.runtime.reconciler.package == packages.atrium-litellm-controller;
    actual-controller-executable = c.services.atrium.runtime.reconciler.executable == "atrium-litellm-controller";
    explicit-identity-bootstrap-installed =
      builtins.fromJSON (builtins.readFile c.environment.etc."atrium/bootstrap/identity.json".source)
      == identity.bootstrap;
    explicit-bootstrap-authority =
      builtins.fromJSON c.environment.etc."atrium/bootstrap/resolver.json".text
      == identity.settings
      && identity.settings.authorities == [ identity.authority ]
      && !identity.settings.isolated_harness
      && identity.registry.principals.ryan.groups == [ ];
    no-implicit-registry = !c.services.atrium.enable && c.services.atrium.registry == null;
    no-policy-publication = c.services.atrium.generated == { }
      && !(c.environment.etc ? "atrium/desired-state/registry.json");
    no-runtime-activation =
      !c.services.atrium.runtime.resolver.enable
      && !c.services.atrium.runtime.reconciler.enable
      && !(c.systemd.services ? atrium-resolver)
      && !(c.systemd.services ? atrium-reconciler)
      && !(c.systemd.timers ? atrium-reconciler);
    no-implicit-credentials =
      c.services.atrium.runtime.resolver.credentials == { }
      && c.services.atrium.runtime.reconciler.credentials == { };
  };
in
assert lib.assertMsg (lib.all (passed: passed) (builtins.attrValues checks))
  ("Atrium Forge preparation failed: " + builtins.toJSON (lib.filterAttrs (_: passed: !passed) checks));
{
  inherit checks;
  kind = "atrium.forge-package-preparation";
  deployment_only = true;
  runtime_gate_evidence = false;
  live_activation = false;
}
