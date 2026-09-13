{ lib, homelabMcp, cloudInventory }:
let
  base = import ./registry-base.nix { inherit lib homelabMcp; };
  acl = principals: groups: { inherit principals groups; };
  personal = acl [ ] [ "atrium-personal-ryan" ];
  family = acl [ ] [ "atrium-family" ];
  configuredModel = name:
    let matches = builtins.filter (model: model.name == name) cloudInventory; in
    assert lib.assertMsg (builtins.length matches == 1)
      "Atrium requires exactly one declared ${name} cloud inventory entry.";
    let model = builtins.head matches; in
    assert lib.assertMsg
      (lib.hasPrefix "anthropic/" model.model
        && !(lib.hasInfix "*" model.model)
        && model.apiKey == "ANTHROPIC_API_KEY"
        && (model.apiBase or null) == null)
      "Review Atrium provider ownership when the declared ${name} transport changes.";
    model.model;
  instance = domain: deployment: route: displayName: eligibility: {
    inherit domain deployment route displayName;
    ownerPrincipal = "ryan";
    affinity = "remote";
    access = "read-only";
    kind = "view";
    audience = deployment;
    authorityBinding = [ "pocketid" ];
    acl = eligibility;
    deviceAcl.mode = "agnostic";
    scopes = [ ];
    permissions = [ ];
  };
  routeTemplate = domain: instance: eligibility: scopes: permissions: {
    inherit domain instance scopes permissions;
    acl = eligibility;
    maxLifetimeSeconds = 900;
  };
  modelTemplate = domain: instance: team: alias: eligibility: {
    inherit domain instance team;
    acl = eligibility;
    models = [ alias ];
    routes = [ "/v1/chat/completions" "/v1/messages" ];
    credentialKind = "client";
    maxLifetimeSeconds = 3600;
    budget = { usd = 1; durationSeconds = 3600; };
  };
  servicePrincipal = displayName: {
    inherit displayName;
    kind = "service";
    roles = [ ];
    groups = [ ];
    bindings = [ ];
  };
  backend = domain: account: credential: model: {
    inherit domain account credential model;
    provider = "anthropic";
  };
  alias = domain: team: backend: {
    inherit domain team;
    owner = "command-center";
    backends = [ backend ];
    fallbacks = [ ];
  };
  imageHosts = {
    openai = "api.openai.com";
    gemini = "generativelanguage.googleapis.com";
    openrouter = "openrouter.ai";
  };
in
lib.recursiveUpdate base {
  groups = {
    atrium-personal-ryan.displayName = "Ryan's Personal wing";
    atrium-family.displayName = "Family wing";
  };
  principals = {
    ryan.groups = [ "atrium-personal-ryan" "atrium-family" ];
    atrium-personal-models = servicePrincipal "Personal wing cloud provider";
    atrium-family-models = servicePrincipal "Family wing cloud provider";
    whiskey-service = servicePrincipal "Whiskey text service";
  };
  deployments = {
    whiskey = {
      adapter = "whiskey";
      endpoint = "https://whiskeywhiskeywhiskey.org";
      viewEnforcement = "server-dispatch";
    };
    litellm = {
      adapter = "litellm";
      endpoint = "https://llm.holthome.net";
      viewEnforcement = "server-dispatch";
    };
  };
  instances = {
    # At explicit native cutover, the retained public OAuth target is a bounded
    # Personal read view, never an implicit admin/Family entitlement.
    personal-data-read = instance "personal:ryan" "home-mcp" "/mcp"
      "Personal wing data"
      personal // {
      scopes = [ "atrium-personal-read" ];
    };
    family-home-read = instance "family:holt" "home-mcp" "/cc/views/family-read"
      "Family wing household information"
      family // {
      scopes = [ "atrium-family-read" ];
    };
    personal-whiskey = instance "personal:ryan" "whiskey" "/cc/mcp"
      "Personal wing Whiskey"
      personal // {
      kind = "deployment";
      access = "read-write";
      permissions = [ "read" "write" ];
    };
    personal-model-sonnet = instance "personal:ryan" "litellm" "/personal/ryan/sonnet"
      "Personal wing Sonnet"
      (personal // { principals = [ "whiskey-service" ]; });
    personal-model-opus = instance "personal:ryan" "litellm" "/personal/ryan/opus"
      "Personal wing Opus (explicit selection)"
      personal;
    family-model-haiku = instance "family:holt" "litellm" "/family/holt/haiku"
      "Family wing Haiku"
      family;
  };
  routeTemplates = {
    "cc.personal.ryan.data-read" = routeTemplate "personal:ryan" "personal-data-read"
      personal [ "atrium-personal-read" ] [ ];
    "cc.family.holt.home-read" = routeTemplate "family:holt" "family-home-read"
      family [ "atrium-family-read" ] [ ];
    "cc.personal.ryan.whiskey" = routeTemplate "personal:ryan" "personal-whiskey"
      personal [ ] [ "read" "write" ];
  };
  providers = {
    anthropic.egressHosts = [ "api.anthropic.com" ];
  } // lib.mapAttrs (_: host: { egressHosts = [ host ]; }) imageHosts;
  serviceCredentials = {
    "cc.personal.ryan.anthropic" = {
      domain = "personal:ryan";
      principal = "atrium-personal-models";
      provider = "anthropic";
      account = "atrium-personal-ryan-anthropic";
      runtimePath = "/run/credentials/atrium-reconciler.service/personal-anthropic";
    };
    "cc.family.holt.anthropic" = {
      domain = "family:holt";
      principal = "atrium-family-models";
      provider = "anthropic";
      account = "atrium-family-holt-anthropic";
      runtimePath = "/run/credentials/atrium-reconciler.service/family-anthropic";
    };
  } // lib.mapAttrs'
    (provider: _: lib.nameValuePair "cc.personal.ryan.whiskey-${provider}" {
      domain = "personal:ryan";
      principal = "whiskey-service";
      inherit provider;
      account = "atrium-personal-ryan-whiskey-${provider}";
      runtimePath = "/run/credentials/atrium-whiskey-images.service/image-${provider}";
    })
    imageHosts;
  modelBackends = {
    "cc.personal.ryan.sonnet" = backend "personal:ryan" "atrium-personal-ryan-anthropic"
      "cc.personal.ryan.anthropic"
      (configuredModel "claude-sonnet");
    "cc.personal.ryan.opus" = backend "personal:ryan" "atrium-personal-ryan-anthropic"
      "cc.personal.ryan.anthropic"
      (configuredModel "claude-opus");
    "cc.family.holt.haiku" = backend "family:holt" "atrium-family-holt-anthropic"
      "cc.family.holt.anthropic"
      (configuredModel "claude-haiku");
  };
  teams = {
    "cc.personal.ryan" = {
      owner = "command-center";
      domain = "personal:ryan";
      models = [ "cc.personal.ryan.sonnet" "cc.personal.ryan.opus" ];
    };
    "cc.family.holt" = {
      owner = "command-center";
      domain = "family:holt";
      models = [ "cc.family.holt.haiku" ];
    };
  };
  aliases = {
    "cc.personal.ryan.sonnet" = alias "personal:ryan" "cc.personal.ryan" "cc.personal.ryan.sonnet";
    "cc.personal.ryan.opus" = alias "personal:ryan" "cc.personal.ryan" "cc.personal.ryan.opus";
    "cc.family.holt.haiku" = alias "family:holt" "cc.family.holt" "cc.family.holt.haiku";
  };
  modelRouting.crossProviderFallback = false;
  modelTemplates = {
    "cc.personal.ryan.sonnet-client" = modelTemplate "personal:ryan" "personal-model-sonnet"
      "cc.personal.ryan" "cc.personal.ryan.sonnet"
      personal;
    "cc.personal.ryan.opus-client" = modelTemplate "personal:ryan" "personal-model-opus"
      "cc.personal.ryan" "cc.personal.ryan.opus"
      personal;
    "cc.family.holt.haiku-client" = modelTemplate "family:holt" "family-model-haiku"
      "cc.family.holt" "cc.family.holt.haiku"
      family;
    "cc.personal.ryan.whiskey-service" = modelTemplate "personal:ryan" "personal-model-sonnet"
      "cc.personal.ryan" "cc.personal.ryan.sonnet"
      (acl [ "whiskey-service" ] [ ]) // {
      routes = [ "/v1/messages" ];
      credentialKind = "service";
      maxLifetimeSeconds = 604800;
      budget = { usd = 2; durationSeconds = 86400; };
      service = {
        principal = "whiskey-service";
        runtimeKeyPath = "/run/atrium-delivery/whiskey/key.json";
        rotationIntervalSeconds = 86400;
        overlapSeconds = 3600;
      };
    };
  };
  providerExceptions = lib.mapAttrs'
    (provider: host: lib.nameValuePair "cc.personal.ryan.whiskey-${provider}-image" {
      instance = "personal-whiskey";
      domain = "personal:ryan";
      inherit provider;
      credential = "cc.personal.ryan.whiskey-${provider}";
      purpose = "image-generation";
      egress = {
        enforcement = "ip";
        hosts = [ host ];
        policyRef = "atrium-forge-whiskey-egress";
      };
    })
    imageHosts;
}
