{ atrium }:
let
  acl = principals: groups: { inherit principals groups; };
  instance = domain: deployment: route: principals: groups: {
    inherit domain deployment route;
    ownerPrincipal = "ryan";
    affinity = if deployment == "sidecar" then "local" else "remote";
    access = "read-only";
    kind = "view";
    displayName = "Isolated fixture";
    audience = deployment;
    authorityBinding = [ "pocket-id-fixture" ];
    acl = acl principals groups;
    deviceAcl.mode = "agnostic";
    scopes = [ ];
    permissions = [ ];
  };
  routeTemplate = domain: instance: principals: groups: scopes: permissions: {
    inherit domain instance scopes permissions;
    acl = acl principals groups;
    maxLifetimeSeconds = 900;
  };
  modelTemplate = domain: instance: team: model: principals: groups: {
    inherit domain instance team;
    acl = acl principals groups;
    models = [ model ];
    routes = [ "/v1/chat/completions" ];
    credentialKind = "client";
    maxLifetimeSeconds = 3600;
    budget = { usd = 1; durationSeconds = 3600; };
  };
  servicePrincipal = displayName: {
    inherit displayName;
    kind = "service";
    roles = [ ];
    bindings = [ ];
  };
  imageProviders = [ "openai" "gemini" "openrouter" ];
  imageCredentials = builtins.listToAttrs (map
    (provider: {
      name = "whiskey-${provider}";
      value = {
        domain = "personal:ryan";
        principal = "whiskey-service";
        inherit provider;
        account = "ryan-isolated-fixture";
        runtimePath = "/run/atrium-fixture/whiskey/${provider}";
      };
    })
    imageProviders);
in
{
  # Forge-owned isolated values, deliberately not imported by forge/default.nix.
  # Identities, catalogs, providers and runtime paths remain synthetic fixtures.
  environment = "isolated";
  domains = {
    "personal:ryan".displayName = "Personal wing";
    "family:holt".displayName = "Family wing";
  };
  authorities.pocket-id-fixture = {
    kind = "pocket-id";
    issuer = "https://pocket-id.atrium.invalid";
    audience = "atrium-isolated-fixture";
    jwksUri = "https://pocket-id.atrium.invalid/.well-known/jwks.json";
    tokenType = "access_token";
  };
  groups = {
    adults.displayName = "Adult fixture participants";
    fixture-children.displayName = "Synthetic child fixtures";
  };
  principals = {
    ryan = {
      displayName = "Ryan";
      kind = "human";
      roles = [ "admin" ];
      groups = [ "adults" ];
      bindings = [{ authority = "pocket-id-fixture"; subject = "synthetic-ryan-subject"; }];
    };
    fixture-child = {
      displayName = "Synthetic child";
      kind = "human";
      roles = [ "child" ];
      groups = [ "fixture-children" ];
      bindings = [{ authority = "pocket-id-fixture"; subject = "synthetic-child-subject"; }];
    };
    whiskey-service = servicePrincipal "Whiskey fixture service";
    personal-model-service = servicePrincipal "Personal wing model fixture";
    family-model-service = servicePrincipal "Family wing model fixture";
  };
  devices.ryan-mac-fixture = {
    displayName = "Synthetic Mac";
    platform = "macos";
    principals = [ "ryan" ];
    domains = [ "personal:ryan" "family:holt" ];
  };
  catalogs = {
    home-mcp-fixture = {
      adapter = "home-mcp";
      source = import (atrium + "/nix/tests/catalog-fixture.nix") { };
    };
    sidecar-fixture = {
      adapter = "sidecar";
      source = import (atrium + "/nix/tests/catalog-fixture.nix") { adapter = "sidecar"; };
    };
  };
  deployments = {
    home-mcp = {
      adapter = "home-mcp";
      endpoint = "https://home-mcp.atrium.invalid";
      catalog = "home-mcp-fixture";
      viewEnforcement = "server-dispatch";
    };
    whiskey = { adapter = "whiskey"; endpoint = "https://whiskey.atrium.invalid"; viewEnforcement = "server-dispatch"; };
    litellm = { adapter = "litellm"; endpoint = "https://litellm.atrium.invalid"; viewEnforcement = "server-dispatch"; };
    sidecar = {
      adapter = "sidecar";
      endpoint = "http://127.0.0.1:18761";
      catalog = "sidecar-fixture";
      viewEnforcement = "server-dispatch";
    };
  };
  instances = {
    family-home-admin = instance "family:holt" "home-mcp" "/cc/views/admin" [ "ryan" ] [ ] // {
      displayName = "Family wing admin fixture";
      access = "read-write";
      scopes = [ "admin" ];
    };
    family-home-adults = instance "family:holt" "home-mcp" "/cc/views/adults" [ ] [ "adults" ] // {
      displayName = "Family wing adult fixture";
      access = "read-write";
      scopes = [ "fixture.read" "fixture.write" ];
    };
    family-home-child = instance "family:holt" "home-mcp" "/cc/views/child" [ "ryan" ] [ "fixture-children" ] // {
      displayName = "Family wing child fixture";
      scopes = [ "fixture.read" ];
    };
    personal-whiskey = instance "personal:ryan" "whiskey" "/cc/mcp" [ "ryan" ] [ ] // {
      displayName = "Personal wing Whiskey fixture";
      kind = "deployment";
      access = "read-write";
      permissions = [ "read" "write" "host" ];
    };
    personal-models = instance "personal:ryan" "litellm" "/personal" [ "ryan" "whiskey-service" ] [ ] // {
      displayName = "Personal wing models";
    };
    family-models = instance "family:holt" "litellm" "/family" [ ] [ "fixture-children" ] // {
      displayName = "Family wing designated model";
    };
    personal-scratch = instance "personal:ryan" "sidecar" "/mcp/scratch" [ "ryan" ] [ ] // {
      displayName = "Personal wing scratch fixture";
      scopes = [ "fixture.read" ];
      deviceAcl = { mode = "required"; devices = [ "ryan-mac-fixture" ]; };
      resourceRoots = [ "/var/lib/atrium-fixture/scratch" ];
    };
  };
  routeTemplates = {
    family-admin = routeTemplate "family:holt" "family-home-admin" [ "ryan" ] [ ] [ "admin" ] [ ];
    family-adults = routeTemplate "family:holt" "family-home-adults" [ ] [ "adults" ]
      [ "fixture.read" "fixture.write" ] [ ];
    family-child-view = routeTemplate "family:holt" "family-home-child" [ "ryan" ] [ "fixture-children" ]
      [ "fixture.read" ] [ ];
    whiskey = routeTemplate "personal:ryan" "personal-whiskey" [ "ryan" ] [ ] [ ] [ "read" "write" "host" ];
    personal-scratch = routeTemplate "personal:ryan" "personal-scratch" [ "ryan" ] [ ] [ "fixture.read" ] [ ];
  };
  providers = {
    fixture-model.egressHosts = [ "models.atrium.invalid" ];
    openai.egressHosts = [ "openai.atrium.invalid" ];
    gemini.egressHosts = [ "gemini.atrium.invalid" ];
    openrouter.egressHosts = [ "openrouter.atrium.invalid" ];
  };
  serviceCredentials = {
    personal-model = {
      domain = "personal:ryan";
      principal = "personal-model-service";
      provider = "fixture-model";
      account = "ryan-isolated-fixture";
      runtimePath = "/run/atrium-fixture/providers/personal-model";
    };
    family-model = {
      domain = "family:holt";
      principal = "family-model-service";
      provider = "fixture-model";
      account = "holt-isolated-fixture";
      runtimePath = "/run/atrium-fixture/providers/family-model";
    };
  } // imageCredentials;
  modelBackends = {
    personal-text = {
      domain = "personal:ryan";
      provider = "fixture-model";
      account = "ryan-isolated-fixture";
      credential = "personal-model";
      model = "fixture/personal-text";
    };
    family-child = {
      domain = "family:holt";
      provider = "fixture-model";
      account = "holt-isolated-fixture";
      credential = "family-model";
      model = "fixture/child-designated";
    };
  };
  teams = {
    "cc.personal.ryan" = {
      owner = "command-center";
      domain = "personal:ryan";
      models = [ "cc.personal.ryan.text" ];
    };
    "cc.family.holt" = {
      owner = "command-center";
      domain = "family:holt";
      models = [ "cc.family.holt.child" ];
    };
  };
  aliases = {
    "cc.personal.ryan.text" = {
      owner = "command-center";
      domain = "personal:ryan";
      team = "cc.personal.ryan";
      backends = [ "personal-text" ];
    };
    "cc.family.holt.child" = {
      owner = "command-center";
      domain = "family:holt";
      team = "cc.family.holt";
      backends = [ "family-child" ];
    };
  };
  modelTemplates = {
    personal-client = modelTemplate "personal:ryan" "personal-models" "cc.personal.ryan"
      "cc.personal.ryan.text" [ "ryan" ] [ ];
    family-child = modelTemplate "family:holt" "family-models" "cc.family.holt"
      "cc.family.holt.child" [ ] [ "fixture-children" ] // {
      budget = { usd = 0.05; durationSeconds = 3600; };
    };
    whiskey-service = modelTemplate "personal:ryan" "personal-models" "cc.personal.ryan"
      "cc.personal.ryan.text" [ "whiskey-service" ] [ ] // {
      credentialKind = "service";
      maxLifetimeSeconds = 604800;
      budget = { usd = 5; durationSeconds = 86400; };
      service = {
        principal = "whiskey-service";
        runtimeKeyPath = "/run/atrium-fixture/whiskey/text-model-key";
        rotationIntervalSeconds = 86400;
        overlapSeconds = 3600;
      };
    };
  };
  providerExceptions = builtins.listToAttrs (map
    (provider: {
      name = "whiskey-${provider}-image";
      value = {
        instance = "personal-whiskey";
        domain = "personal:ryan";
        inherit provider;
        credential = "whiskey-${provider}";
        purpose = "image-generation";
        egress = {
          enforcement = "hostname";
          hosts = [ "${provider}.atrium.invalid" ];
          policyRef = "fixture-${provider}-egress";
        };
      };
    })
    imageProviders);
}
