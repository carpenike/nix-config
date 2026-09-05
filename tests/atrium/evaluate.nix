{ atriumFlake }:
let
  # The caller supplies the exact approved flake ref; no guessed GitHub availability.
  atrium = builtins.getFlake atriumFlake;
  inherit (atrium.inputs.nixpkgs) lib;
  registry = import ./registry.nix { inherit atrium; };
  documents = atrium.lib.render registry;
  host = lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit atrium; };
    modules = [ ./host.nix ];
  };
  patch = changes: lib.recursiveUpdate registry changes;
  accepts = value: (builtins.tryEval (builtins.deepSeq (atrium.lib.render value) true)).success;
  mutations = {
    T5-static-foreign-team = patch { modelTemplates.family-child.team = "cc.personal.ryan"; };
    T6-static-foreign-instance = patch { routeTemplates.family-child-view.domain = "personal:ryan"; };
    T7-static-adult-acl = patch { routeTemplates.family-adults.acl.principals = [ "fixture-child" ]; };
    T9-static-scope-ceiling = patch { routeTemplates.family-child-view.scopes = [ "fixture.write" ]; };
    T11-static-retired-scope = patch { instances.family-home-child.scopes = [ "retired.read" ]; };
    T22-static-foreign-backend = patch { aliases."cc.family.holt.child".backends = [ "personal-text" ]; };
    missing-team-owner = registry // {
      teams = registry.teams // { "cc.family.holt" = builtins.removeAttrs registry.teams."cc.family.holt" [ "owner" ]; };
    };
    incomplete-provider-exception = registry // {
      providerExceptions = registry.providerExceptions // {
        whiskey-openai-image = builtins.removeAttrs registry.providerExceptions.whiskey-openai-image [ "credential" ];
      };
    };
    wrong-authority = patch { instances.family-home-child.authorityBinding = [ "unlinked-authority" ]; };
    missing-device-evidence-policy = patch { instances.personal-scratch.deviceAcl = { mode = "agnostic"; devices = [ ]; }; };
    management-route = patch { modelTemplates.personal-client.routes = [ "/team/update" ]; };
    secret-store-path = patch { serviceCredentials.personal-model.runtimePath = "/nix/store/fixture-key"; };
  };
  permit = accepts registry;
  pairs = lib.mapAttrs (_: mutation: { permit = permit; deny = !accepts mutation; }) mutations;
  structural = {
    only-initial-domains = builtins.attrNames documents.registry.domains == [ "family:holt" "personal:ryan" ];
    only-new-owned-teams = documents.litellm.ownership.managed_team_ids == [ "cc.family.holt" "cc.personal.ryan" ];
    synthetic-child-only = documents.resolver.principals.fixture-child.bindings == [ {
      authority = "pocket-id-fixture"; subject = "synthetic-child-subject";
    } ];
    one-home-deployment = builtins.attrNames documents.homeMcp.deployments == [ "home-mcp" ];
    child-source-derived-view = documents.homeMcp.instances.family-home-child.tool_allowlist == [ "fixture_read" ];
    child-source-derived-resource = documents.homeMcp.instances.family-home-child.resource_allowlist == [ "fixture://notes" ];
    scoped-administrator = documents.resolver.route_templates.family-child-view.scopes == [ "fixture.read" ];
    preserves-image-exceptions = builtins.attrNames documents.whiskey.provider_exceptions
      == [ "whiskey-gemini-image" "whiskey-openai-image" "whiskey-openrouter-image" ];
    no-runtime-services = !(host.config.systemd.services ? atrium-resolver)
      && !(host.config.systemd.services ? atrium-reconciler);
    isolated-host-name = host.config.networking.hostName == "atrium-fixture";
    no-listening-ports = host.config.networking.firewall.allowedTCPPorts == [ ];
    six-generated-documents = lib.length (builtins.attrNames host.config.services.atrium.generated) == 6;
    valid-host-assertions = lib.all (item: item.assertion) host.config.assertions;
  };
  success = lib.all (pair: pair.permit && pair.deny) (builtins.attrValues pairs)
    && lib.all (value: value) (builtins.attrValues structural);
in
assert success;
{
  inherit documents;
  report = {
    schema_version = 1;
    kind = "atrium.nix-config-static-evaluation";
    inherit success pairs structural;
    pair_count = lib.length (builtins.attrNames pairs);
    structural_count = lib.length (builtins.attrNames structural);
    atrium_revision = atrium.rev or null;
    runtime_gate_evidence = false;
    blocked_runtime_gates = [ "T5" "T6" "T7" "T9" "T11" "T22" ];
  };
}
