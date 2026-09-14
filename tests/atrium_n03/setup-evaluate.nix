{ inputs, pkgs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  baseline = forge.config;
  registry = baseline.services.atrium.registry;
  bootstrap = import ../../hosts/forge/atrium/bootstrap.nix { inherit lib registry; };
  operator = bootstrap.groups.operator_membership;
  authority = registry.authorities.${bootstrap.groups.authority};
  admissionPath = ../../hosts/forge/atrium/setup-admission.nix;
  placeholder = "# Managed by atrium setup; no client is admitted until verified.\n{ ... }: { }\n";
  hostModule = import ../../hosts/forge/services/atrium.nix {
    inherit inputs pkgs lib;
    config = baseline;
    mylib = { };
  };
  # Models the frontend's verified result, not a real provider client/admission.
  verifiedFixtureClient = "fixture-verified-setup-client";
  configured = (forge.extendModules {
    modules = [
      {
        disabledModules = [ admissionPath ];
        imports = [
          ({ ... }: {
            services.atriumForge.groupEvidence.clientIds = [ verifiedFixtureClient ];
          })
        ];
      }
    ];
  }).config;
  installed = builtins.fromJSON baseline.environment.etc."atrium/bootstrap/setup.json".text;
  exported = inputs.self.lib.atriumSetupConfigs.forge;
  configuredManifest = builtins.fromJSON configured.environment.etc."atrium/bootstrap/setup.json".text;
  configuredSettings = builtins.fromJSON configured.environment.etc."atrium/runtime/atrium-resolver.json".text;
  unconfiguredSettings = builtins.fromJSON baseline.environment.etc."atrium/runtime/atrium-resolver.json".text;
  startup = config: unit: config.systemd.services.${unit}.serviceConfig.ExecStartPre or [ ];
  expectedGroups = map
    (name: {
      inherit name;
      friendly_name = registry.groups.${name}.displayName;
      member_subjects = [ operator.subject ];
    })
    operator.groups;
  modelAdopted = (forge.extendModules {
    modules = [{
      services.atriumForge = {
        groupEvidence.clientIds = [ verifiedFixtureClient ];
        adoption.models = true;
      };
    }];
  }).config;
  secretSources = map
    (credential: lib.concatStringsSep ":" (builtins.tail (lib.splitString ":" credential)))
    (modelAdopted.systemd.services.atrium-reconciler.serviceConfig.LoadCredential
      ++ lib.filter (lib.hasPrefix "model-management:")
      modelAdopted.systemd.services.atrium-resolver.serviceConfig.LoadCredential);
  checks = {
    manifest-export-install-parity = exported == installed;
    schema-root-exact = builtins.attrNames exported == [
      "deployment"
      "host"
      "initialization"
      "installation"
      "pocket_id"
      "required_secrets"
      "schema_version"
    ] && exported.schema_version == 1;
    schema-pocket-id-exact = builtins.attrNames exported.pocket_id == [
      "access_token_minutes"
      "client_id"
      "groups"
      "issuer"
      "principal"
      "redirect_uri"
      "refresh_token_minutes"
      "resource"
      "subject"
    ];
    actual-host-installation = exported.host == baseline.networking.hostName
      && exported.host == "forge" && exported.installation == "atrium-forge";
    authoritative-identity-values = exported.pocket_id.issuer == authority.issuer
      && exported.pocket_id.resource == authority.audience
      && exported.pocket_id.principal == operator.principal
      && exported.pocket_id.subject == operator.subject
      && lib.any
      (binding: binding.authority == bootstrap.groups.authority
        && binding.subject == operator.subject)
      registry.principals.${operator.principal}.bindings;
    explicit-proposed-setup-defaults = exported.pocket_id.client_id == "cc.atrium.operator"
      && exported.pocket_id.redirect_uri == "http://127.0.0.1:18889/callback"
      && exported.pocket_id.access_token_minutes == 14
      && exported.pocket_id.refresh_token_minutes == 60;
    exact-desired-group-plan = exported.pocket_id.groups == expectedGroups
      && lib.all (group: builtins.attrNames group == [ "friendly_name" "member_subjects" "name" ])
      exported.pocket_id.groups;
    narrow-relative-admission-path = exported.deployment == {
      admission_file = "hosts/forge/atrium/setup-admission.nix";
    };
    exact-safe-placeholder = builtins.readFile admissionPath == placeholder
      && builtins.stringLength placeholder == 78
      && builtins.hashString "sha256" placeholder
      == "2a268c80ad7c1bd389b7ed6bd85f9f9101603a5126e07591c303b64589705125";
    actual-managed-import = lib.elem admissionPath hostModule.imports;
    named-client-is-not-admitted = baseline.services.atriumForge.groupEvidence == null
      && lib.all (authority: !(authority ? group_evidence)) unconfiguredSettings.authorities;
    safe-default-retains-startup-refusal = lib.all
      (unit: lib.length (startup baseline unit) == 1
        && lib.hasInfix "atrium-c10-unconfigured" (builtins.head (startup baseline unit)))
      [ "atrium-resolver" "atrium-device-registration" ];
    verified-fragment-admits-only-explicit-result =
      configured.services.atriumForge.groupEvidence.clientIds == [ verifiedFixtureClient ]
      && configured.services.atriumForge.groupEvidence.maxTokenLifetimeSeconds == 3600
      && (builtins.head configuredSettings.authorities).group_evidence.client_ids
      == [ verifiedFixtureClient ]
      && !lib.elem exported.pocket_id.client_id configured.services.atriumForge.groupEvidence.clientIds;
    proposed-plan-does-not-become-registration-status = configuredManifest == exported;
    configured-removes-only-missing-client-preflight = lib.all
      (unit: startup configured unit == [ ])
      [ "atrium-resolver" "atrium-device-registration" ];
    no-adoption-flag-widening = configured.services.atriumForge.adoption == baseline.services.atriumForge.adoption
      && lib.all (enabled: !enabled) (builtins.attrValues configured.services.atriumForge.adoption);
    no-policy-budget-or-credential-widening = configured.services.atrium.registry == registry;
    no-grant-enrollment-or-group-observation-change = lib.all
      (name: configured.environment.etc."atrium/bootstrap/${name}.json".text
        == baseline.environment.etc."atrium/bootstrap/${name}.json".text)
      [ "identity" "ordinary-grants" "groups" "opus-selection" ];
    exact-initialization-plan = exported.initialization == {
      ssh_target = "${baseline.users.users.ryan.name}@${baseline.networking.hostName}.${baseline.networking.domain}";
      units = [ "atrium-initialize" "atrium-trust-initialize" "atrium-seed-policy" ];
    };
    initializers-remain-manual = lib.all
      (name: baseline.systemd.services.${name}.wantedBy == [ ]
        && !lib.elem "${name}.service" baseline.systemd.services.atrium-resolver.requires)
      exported.initialization.units;
    secret-references-match-real-wiring =
      lib.sort builtins.lessThan (map (secret: secret.name) exported.required_secrets)
      == lib.sort builtins.lessThan secretSources
      && lib.all
        (secret: builtins.attrNames secret == [ "name" "purpose" ]
        && lib.hasPrefix "/run/secrets/" secret.name && secret.purpose != "")
        exported.required_secrets;
    independent-of-worktree-or-store-path =
      !lib.hasInfix "/Users/" (builtins.toJSON exported)
      && !lib.hasInfix "/nix/store/" (builtins.toJSON exported)
      && !lib.hasInfix "/tmp/" (builtins.toJSON exported);
    existing-health-tls-firewall-preserved =
      configured.networking.firewall.extraCommands == baseline.networking.firewall.extraCommands
      && configured.modules.services.litellm.models == baseline.modules.services.litellm.models
      && configured.modules.services.litellm.image == baseline.modules.services.litellm.image
      && configured.environment.etc."atrium/bootstrap/tls-plan.json".text
      == baseline.environment.etc."atrium/bootstrap/tls-plan.json".text;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium setup manifest failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.setup-manifest-admission-integration";
  schema_version = 1;
  fixture_admission_only = true;
  live_objects_created = false;
  native_setup_command_executed = false;
  placeholder_sha256 = builtins.hashString "sha256" placeholder;
}
