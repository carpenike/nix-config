{ inputs, candidateRuntime, candidateNative, scopeState ? "live" }:
let
  inherit (inputs.nixpkgs) lib;
  base = import ./fixture.nix { inherit inputs; enableModels = true; };
  installation = "atrium-n02-production-envelope";
  names = base.names // {
    providerPersonal = "personal.models.atrium.invalid";
    providerFamily = "family.models.atrium.invalid";
  };
  endpoints = base.endpoints // {
    providerPersonal = "https://${names.providerPersonal}:${toString base.port}";
    providerFamily = "https://${names.providerFamily}:${toString base.port}";
  };
  catalog = builtins.fromJSON (builtins.readFile
    (candidateNative + "/tests/fixtures/atrium_m03_catalog.generated.json"));
  retiredCatalog = catalog // {
    scopes = catalog.scopes // {
      "fixture.read" = catalog.scopes."fixture.read" // { status = "retired"; };
    };
  };
  withoutRetiredScope = value: value // {
    scopes = lib.filter (name: name != "fixture.read") value.scopes;
  } // lib.optionalAttrs (lib.filter (name: name != "fixture.read") value.scopes == [ ]) {
    status = "retired";
  };
  registry = base.registry // {
    environment = "production";
    authorities = lib.mapAttrs (_: value: value // { kind = "pocket-id"; }) base.registry.authorities;
    catalogs = base.registry.catalogs // {
      home-mcp-fixture = base.registry.catalogs.home-mcp-fixture // {
        source =
          if scopeState == "live" then
            candidateNative + "/tests/fixtures/atrium_m03_catalog.generated.json"
          else builtins.toFile "atrium-n02-retired-source-catalog.json" (builtins.toJSON retiredCatalog);
      };
    };
    instances = lib.mapAttrs
      (_: value:
        if scopeState == "retired" && value.deployment == "home-mcp"
        then withoutRetiredScope value else value)
      base.registry.instances;
    routeTemplates = lib.mapAttrs
      (_: value:
        if scopeState == "retired" && base.registry.instances.${value.instance}.deployment == "home-mcp"
        then withoutRetiredScope value else value)
      base.registry.routeTemplates;
  };
  generated = candidateRuntime.lib.render registry;
  application = {
    available = lib.all
      (system: lib.all
        (name: builtins.hasAttr name candidateRuntime.packages.${system})
        [ "resolver" "sidecar" "atrium-litellm-controller" "atrium-litellm-admission" ])
      [ "x86_64-linux" "aarch64-linux" ];
    revision = candidateRuntime.rev;
    repository = "carpenike/atrium";
    scope = "explicit candidate package selection, not accepted runtime qualification";
    qualified = false;
  };
  initialModels = import ./models.nix {
    inherit lib registry generated endpoints application;
    inherit (base) ids runtime state;
  };
  providerEndpoints = {
    "personal:ryan" = endpoints.providerPersonal;
    "family:holt" = endpoints.providerFamily;
  };
  models = lib.recursiveUpdate initialModels {
    inherit installation;
    activation = "isolated native qualification only; reviewed runtime and owned lease required";
    resolver.installation = installation;
    controller = {
      inherit installation;
      environment = "production";
      endpoint = endpoints.models;
      backend_transports = lib.mapAttrs
        (_: backend: {
          api_base = "${providerEndpoints.${backend.domain}}/v1";
        })
        registry.modelBackends;
    };
    admission = { inherit installation; environment = "production"; isolated = false; };
    actorEnvironment.SSL_CERT_FILE = "${base.runtime}/model-inputs/front-ca";
    gatewayEnvironment.SSL_CERT_FILE = "${base.runtime}/model-inputs/front-ca";
  };
  secureResolver = settings: settings // { isolated_harness = false; };
in
assert builtins.elem scopeState [ "live" "retired" ];
assert builtins.match "[0-9a-f]{40}" candidateRuntime.rev != null;
assert candidateNative.rev == "f961dc1db9b38c8baa1ae09624fdfa27ddf7bd7f";
assert application.available;
base // {
  inherit names endpoints registry generated models;
  modelPlaneReady = true;
  modelPlaneBlocker = "reviewed-candidate-and-owned-native-lease-required";
  versions = base.versions // {
    atrium = candidateRuntime.rev;
    native = candidateNative.rev;
  };
  resolver = (secureResolver base.resolver) // { litellm = models.resolver; };
  registration = secureResolver base.registration;
  nativePolicy = secureResolver base.nativePolicy;
  whiskey = base.whiskey // { isolated_harness = false; };
  whiskeyModel = base.whiskeyModel // { inherit installation; isolated_harness = false; };
  qualification = {
    kind = "atrium.n02-production-envelope";
    environment = "production";
    physical_isolation = true;
    reviewed_runtime_required = true;
    inherit scopeState;
    delegating_template = "personal-client";
    provider_upstreams = {
      "personal:ryan" = "http://personal-upstream.models.atrium.invalid:8000";
      "family:holt" = "http://family-upstream.models.atrium.invalid:8000";
    };
    provider_endpoints = providerEndpoints;
    candidate_runtime = candidateRuntime.rev;
    candidate_native = candidateNative.rev;
    accepted_pins_modified = false;
    mutable_mismatch_policy = (candidateRuntime.lib.render (registry // {
      environment = "isolated";
    })).resolver;
  };
}
