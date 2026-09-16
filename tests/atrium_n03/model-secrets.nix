{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = import ./pre-adoption.nix { inherit inputs; };
  baseline = forge.config;
  disabled = (forge.extendModules {
    modules = [{ services.atriumForge.enable = lib.mkForce false; }];
  }).config;
  adopted = (forge.extendModules {
    modules = [{ services.atriumForge.adoption.models = true; }];
  }).config;
  expected = {
    atrium-personal-anthropic = {
      key = "atrium/personal_anthropic_api_key";
      consumer = "atrium-reconciler.service";
    };
    atrium-family-anthropic = {
      key = "atrium/family_anthropic_api_key";
      consumer = "atrium-reconciler.service";
    };
    atrium-litellm-resolver-management = {
      key = "atrium/litellm_resolver_management_key";
      consumer = "atrium-resolver.service";
    };
    atrium-litellm-controller-management = {
      key = "atrium/litellm_controller_management_key";
      consumer = "atrium-reconciler.service";
    };
  };
  names = builtins.attrNames expected;
  checks = {
    all-four-credentials-staged-before-adoption =
      lib.all (name: builtins.hasAttr name baseline.sops.secrets) names;
    exact-encrypted-key-and-runtime-path = lib.all
      (name:
        let secret = baseline.sops.secrets.${name};
        in secret.key == expected.${name}.key
          && secret.path == "/run/secrets/${name}"
          && secret.sopsFile == ../../hosts/forge/secrets.sops.yaml)
      names;
    root-only-runtime-custody = lib.all
      (name:
        let secret = baseline.sops.secrets.${name};
        in secret.owner == "root" && secret.group == "root" && secret.mode == "0400")
      names;
    no-secret-triggered-service-start-before-adoption =
      lib.all (name: baseline.sops.secrets.${name}.restartUnits == [ ]) names;
    only-intended-consumer-restarts-after-adoption = lib.all
      (name: adopted.sops.secrets.${name}.restartUnits == [ expected.${name}.consumer ])
      names;
    disabled-atrium-does-not-declare-new-secrets =
      lib.all (name: !(builtins.hasAttr name disabled.sops.secrets)) names;
    existing-secret-declarations-preserved =
      builtins.removeAttrs baseline.sops.secrets names == disabled.sops.secrets;
    provider-and-management-sources-remain-distinct =
      lib.length (lib.unique (map (name: baseline.sops.secrets.${name}.key) names)) == 4;
    model-and-native-adoption-remain-explicit =
      lib.all (enabled: !enabled) (builtins.attrValues baseline.services.atriumForge.adoption);
    initializers-are-never-secret-restart-targets =
      lib.all
        (name: !lib.any (unit: lib.hasInfix "initialize" unit || lib.hasInfix "seed-policy" unit)
          adopted.sops.secrets.${name}.restartUnits)
        names;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium model secret scaffold failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.model-secret-scaffold";
  secret_values_inspected = false;
  runtime_credentials_provisioned = false;
  model_adoption_enabled = false;
}
