{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  baseline = forge.config;
  # Configuration fixtures only: not discovered or provisioned provider clients.
  fixtureClients = [ "fixture-c10-public-client" "fixture-c10-public-client-2" ];
  configured = (forge.extendModules {
    modules = [{
      services.atriumForge.groupEvidence.clientIds = fixtureClients;
    }];
  }).config;
  adoptedWithoutClients = (forge.extendModules {
    modules = [{ services.atriumForge.adoption.models = true; }];
  }).config;
  configuredNative = (forge.extendModules {
    modules = [{
      services.atriumForge = {
        groupEvidence.clientIds = fixtureClients;
        adoption.native = true;
      };
    }];
  }).config;
  parse = config: name: builtins.fromJSON config.environment.etc."atrium/${name}.json".text;
  settings = parse configured "runtime/atrium-resolver";
  unconfigured = parse baseline "runtime/atrium-resolver";
  admission = parse configured "runtime/adoption";
  withoutAdmission = parse baseline "runtime/adoption";
  canEvaluate = value: (builtins.tryEval (builtins.deepSeq
    (forge.extendModules {
      modules = [{ services.atriumForge.groupEvidence = value; }];
    }).config.services.atriumForge.groupEvidence
    true)).success;
  adoptionChecks = lib.filter
    (assertion: !assertion.assertion
      && lib.hasPrefix "Atrium adoption requires explicit operator-verified" assertion.message)
    adoptedWithoutClients.assertions;
  startup = config: unit: config.systemd.services.${unit}.serviceConfig.ExecStartPre or [ ];
  checks = {
    c10-accepted = withoutAdmission.identity.group_evidence.amendment.accepted
      && withoutAdmission.identity.group_evidence.amendment.acceptance_revision == "e8e4d54";
    no-default-client = baseline.services.atriumForge.groupEvidence == null
      && withoutAdmission.identity.group_evidence.admitted_client_ids == [ ]
      && withoutAdmission.identity.group_evidence.status == "accepted-unconfigured";
    unconfigured-authority-omits-carrier = lib.all
      (authority: !(authority ? group_evidence))
      unconfigured.authorities;
    unconfigured-startup-refuses = lib.all
      (unit: lib.length (startup baseline unit) == 1
        && lib.hasInfix "atrium-c10-unconfigured" (builtins.head (startup baseline unit)))
      [ "atrium-resolver" "atrium-device-registration" ];
    unconfigured-adoption-refuses = lib.length adoptionChecks == 1
      && !(builtins.head adoptionChecks).assertion;
    configured-startup-removes-only-missing-config-refusal = lib.all
      (unit: startup configured unit == [ ])
      [ "atrium-resolver" "atrium-device-registration" ];
    explicit-exact-client-list = settings.group_authority == "pocketid"
      && (builtins.head settings.authorities).group_evidence == {
      client_ids = fixtureClients;
      max_token_lifetime_seconds = 3600;
    }
      && admission.identity.group_evidence.admitted_client_ids == fixtureClients;
    selected-authority-only = lib.all
      (authority: !(authority ? group_evidence) || authority.id == settings.group_authority)
      settings.authorities;
    all-runtime-settings-share-admission = lib.all
      (document: (builtins.head document.authorities).group_evidence
        == (builtins.head settings.authorities).group_evidence
        && document.group_authority == "pocketid")
      [
        (parse configured "runtime/atrium-device-registration")
        (parse configured "bootstrap/foundation")
        (parse configuredNative "runtime/native-policy.template")
      ];
    identity-bootstrap-is-not-group-admission = lib.all
      (authority: !(authority ? group_evidence))
      (parse configured "bootstrap/resolver").authorities;
    no-membership-or-identity-widening =
      configured.services.atrium.registry == baseline.services.atrium.registry
      && configured.environment.etc."atrium/bootstrap/identity.json".text
      == baseline.environment.etc."atrium/bootstrap/identity.json".text
      && configured.environment.etc."atrium/bootstrap/ordinary-grants.json".text
      == baseline.environment.etc."atrium/bootstrap/ordinary-grants.json".text
      && !(parse configured "bootstrap/groups").observations_seeded
      && admission.identity.group_evidence.resource_authentication == "access-token-bearer-only"
      && !admission.identity.group_evidence.identity_carrier_change;
    no-inferred-live-client-or-native-proof =
      !admission.identity.group_evidence.live_client_provisioning_performed
      && !admission.identity.group_evidence.native_c10_qualification_executed_here
      && admission.identity.group_evidence.supplied_qualification.core_revision
      == "ca621d753529b3ba89e67fef6f3c3f80aade332d"
      && !admission.identity.group_evidence.supplied_qualification.proves_live_client_admission;
    empty-client-list-refused = !canEvaluate { clientIds = [ ]; };
    wildcard-client-refused = !canEvaluate { clientIds = [ "*" ]; };
    wildcard-pattern-refused = !canEvaluate { clientIds = [ "fixture-*" ]; };
    duplicate-client-refused = !canEvaluate { clientIds = [ "fixture-client" "fixture-client" ]; };
    blank-client-refused = !canEvaluate { clientIds = [ "" ]; };
    whitespace-client-refused = !canEvaluate { clientIds = [ " fixture-client" ]; };
    control-character-refused = !canEvaluate { clientIds = [ "fixture\nclient" ]; };
    oversized-client-refused = !canEvaluate { clientIds = [ (lib.concatStrings (lib.replicate 513 "x")) ]; };
    too-many-clients-refused = !canEvaluate {
      clientIds = map (number: "fixture-client-${toString number}") (lib.range 1 65);
    };
    wider-source-lifetime-refused = !canEvaluate {
      clientIds = fixtureClients;
      maxTokenLifetimeSeconds = 7200;
    };
  };
  packages = inputs.atrium.packages.${pkgs.stdenv.hostPlatform.system};
  python = pkgs.python312.withPackages (ps: [ (ps.toPythonModule packages.resolver) ]);
  documents = {
    inherit settings unconfigured;
    registration = parse configured "runtime/atrium-device-registration";
    foundation = parse configured "bootstrap/foundation";
    identityOnly = parse configured "bootstrap/resolver";
  };
in
{
  evaluation =
    assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
      ("Atrium C10 settings failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
    pkgs.writeText "atrium-forge-c10-settings.json" (builtins.toJSON {
      inherit checks;
      kind = "atrium.forge-c10-settings";
      configured_clients_are_test_fixtures = true;
      native_qualification = false;
      live_operations = false;
    });
  schema = pkgs.runCommand "atrium-forge-c10-schema"
    { nativeBuildInputs = [ python ]; PYTHONDONTWRITEBYTECODE = "1"; }
    ''
      python - <<'PY' > "$out"
      import copy
      import json
      from atrium_resolver.config import Settings
      from pydantic import ValidationError

      documents = json.loads(${builtins.toJSON (builtins.toJSON documents)})
      for name in ("settings", "registration", "foundation"):
          settings = Settings.model_validate_json(json.dumps(documents[name]))
          admitted = [a for a in settings.authorities if a.group_evidence is not None]
          assert len(admitted) == 1 and admitted[0].id == settings.group_authority == "pocketid"
          assert admitted[0].group_evidence.client_ids == (
              "fixture-c10-public-client", "fixture-c10-public-client-2",
          )
          assert admitted[0].group_evidence.max_token_lifetime_seconds == 3600
          assert admitted[0].audience == "https://atrium.holthome.net/resolver"
          assert admitted[0].algorithms == ("RS256",)
      for name in ("unconfigured", "identityOnly"):
          settings = Settings.model_validate_json(json.dumps(documents[name]))
          assert all(authority.group_evidence is None for authority in settings.authorities)
      wrong = copy.deepcopy(documents["settings"])
      wrong["group_authority"] = None
      try:
          Settings.model_validate_json(json.dumps(wrong))
      except ValidationError:
          pass
      else:
          raise AssertionError("group evidence admitted without selected group authority")
      print(json.dumps({
          "kind": "atrium.forge-c10-schema", "status": "passed",
          "actual_settings_parser": True, "fixture_clients_only": True,
          "native_qualification": False, "live_operations": False,
      }))
      PY
    '';
}
