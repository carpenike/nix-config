{ inputs, pkgs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  baseline = (forge.extendModules {
    modules = [{
      disabledModules = [ admissionPath ];
      imports = [ fixtureAdmission ];
    }];
  }).config;
  registry = baseline.services.atrium.registry;
  bootstrap = import ../../hosts/forge/atrium/bootstrap.nix { inherit lib registry; };
  operator = bootstrap.groups.operator_membership;
  authority = registry.authorities.${bootstrap.groups.authority};
  admissionPath = ../../hosts/forge/atrium/setup-admission.nix;
  placeholder = "# Managed by atrium setup; no client is admitted until verified.\n{ ... }: { }\n";
  fixtureAdmission = builtins.toFile "atrium-fixture-empty-admission.nix" placeholder;
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
  units = baseline.systemd.services;
  foundationCheck = units.atrium-foundation-check;
  foundationService = foundationCheck.serviceConfig;
  resolverState = unconfiguredSettings.state_directory;
  resolverPackage = inputs.atrium.packages.${baseline.nixpkgs.hostPlatform.system}.resolver;
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
    exact-safe-placeholder = builtins.readFile fixtureAdmission == placeholder
      && builtins.stringLength placeholder == 78
      && builtins.hashString "sha256" placeholder
      == "2a268c80ad7c1bd389b7ed6bd85f9f9101603a5126e07591c303b64589705125";
    actual-managed-import = lib.elem admissionPath hostModule.imports;
    named-client-is-not-admitted = baseline.services.atriumForge.groupEvidence == null
      && lib.all (authority: !(authority ? group_evidence)) unconfiguredSettings.authorities;
    safe-default-retains-startup-refusal = lib.all
      (unit: lib.length (startup baseline unit) == 2
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
      (unit: lib.length (startup configured unit) == 1
        && lib.hasInfix "credential-projection.py" (builtins.head (startup configured unit)))
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
    foundation-exact-check-command = foundationService.ExecStart
      == "${lib.getExe resolverPackage} --config /etc/atrium/bootstrap/foundation.json check-foundation --enrollment /etc/atrium/bootstrap/identity.json --installation ${exported.installation}"
      && foundationCheck.script == ""
      && (foundationService.ExecStartPre or [ ]) == [ ]
      && (foundationService.ExecStartPost or [ ]) == [ ];
    foundation-reuses-private-protections =
      builtins.removeAttrs foundationService [ "ExecStart" "ReadOnlyPaths" "StandardOutput" ]
      == builtins.removeAttrs units.atrium-initialize.serviceConfig [
        "ExecStart"
        "StateDirectory"
        "StateDirectoryMode"
        "ReadWritePaths"
      ];
    foundation-resolver-custody-not-tls = foundationService.User == "atrium-resolver"
      && foundationService.Group == "atrium-resolver"
      && baseline.users.users.atrium-resolver.uid == 1060
      && units.atrium-trust-check.serviceConfig.User == "atrium-trust"
      && baseline.users.users.atrium-trust.uid == 1061
      && !(foundationService ? LoadCredential)
      && lib.hasSuffix "tls --plan /etc/atrium/bootstrap/tls-plan.json status"
      units.atrium-trust-check.serviceConfig.ExecStart;
    foundation-requires-existing-mount-and-state =
      foundationCheck.requires == [ "zfs-service-datasets.service" ]
      && foundationCheck.after == [ "zfs-service-datasets.service" ]
      && foundationCheck.unitConfig.RequiresMountsFor == [ resolverState ]
      && foundationCheck.unitConfig.AssertFileNotEmpty == [
        "${resolverState}/foundation.initialized"
        "${resolverState}/resolver.sqlite3"
      ];
    foundation-no-state-creation-or-write-grant =
      !(foundationService ? StateDirectory) && !(foundationService ? StateDirectoryMode)
      && (foundationService.ReadWritePaths or [ ]) == [ ]
      && foundationService.ReadOnlyPaths == [ resolverState ]
      && (foundationService.RuntimeDirectory or [ ]) == [ ]
      && (foundationService.CacheDirectory or [ ]) == [ ]
      && (foundationService.LogsDirectory or [ ]) == [ ];
    foundation-network-free-repeatable-oneshot =
      foundationService.Type == "oneshot" && foundationService.PrivateNetwork
      && !(foundationService.RemainAfterExit or false)
      && (foundationService.Restart or "no") == "no"
      && foundationService.StandardOutput == "null";
    foundation-manual-not-an-initializer =
      foundationCheck.wantedBy == [ ] && foundationCheck.requiredBy == [ ]
      && foundationCheck.wants == [ ]
      && !(baseline.systemd.timers ? atrium-foundation-check)
      && !lib.elem "atrium-foundation-check" exported.initialization.units
      && !lib.elem "atrium-trust-check" exported.initialization.units
      && lib.all
        (name: !lib.elem "atrium-foundation-check.service" (units.${name}.requires ++ units.${name}.wants))
        (exported.initialization.units ++ [ "atrium-resolver" "atrium-device-registration" ]);
    foundation-configured-admission-does-not-change-custody =
      configured.systemd.services.atrium-foundation-check.serviceConfig == foundationService
      && configured.systemd.services.atrium-foundation-check.unitConfig == foundationCheck.unitConfig;
    foundation-check-failure-alert =
      baseline.modules.alerting.rules.atrium-foundation-check-failed.expr
      == ''node_systemd_unit_state{name="atrium-foundation-check.service",state="failed"} == 1''
      && baseline.modules.alerting.rules.atrium-foundation-check-failed.severity == "high";
    foundation-existing-protection-coverage =
      baseline.modules.storage.datasets.services.atrium-resolver.owner == foundationService.User
      && baseline.modules.storage.datasets.services.atrium-resolver.mode == "0700"
      && !baseline.modules.storage.datasets.services.atrium-resolver.protection.allowEmptyBootstrap
      && baseline.modules.services.backup.restic.jobs.atrium-resolver.paths == [ resolverState ]
      && baseline.modules.services.backup.restic.jobs.atrium-resolver-offsite.paths == [ resolverState ]
      && !(baseline.modules.storage.datasets.services ? atrium-foundation-check);
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
  foundation_check_executed = false;
  placeholder_sha256 = builtins.hashString "sha256" placeholder;
}
