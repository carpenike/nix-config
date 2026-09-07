{ atrium }:
let
  base = import ../atrium/registry.nix { inherit atrium; };
  registry = atrium.inputs.nixpkgs.lib.recursiveUpdate base {
    instances.family-models.acl.principals = [ "ryan" ];
    modelBackends = {
      personal-text.model = "openai/fixture-personal";
      family-child.model = "openai/fixture-family";
      family-adult = {
        domain = "family:holt";
        provider = "fixture-model";
        account = "holt-isolated-fixture";
        credential = "family-model";
        model = "openai/fixture-personal";
      };
    };
    aliases."cc.family.holt.adult" = {
      owner = "command-center";
      domain = "family:holt";
      team = "cc.family.holt";
      backends = [ "family-adult" ];
    };
    teams."cc.family.holt".models = [ "cc.family.holt.child" "cc.family.holt.adult" ];
    modelTemplates = {
      personal-retiring = base.modelTemplates.personal-client;
      family-adult = base.modelTemplates.family-child // {
        models = [ "cc.family.holt.adult" ];
        acl = { principals = [ "ryan" ]; groups = [ ]; };
      };
      whiskey-service = base.modelTemplates.whiskey-service // {
        maxLifetimeSeconds = 600;
        service = {
          principal = "whiskey-service";
          runtimeKeyPath = "/run/atrium-n04/delivery/key.json";
          rotationIntervalSeconds = 2;
          overlapSeconds = 2;
        };
      };
    };
  };
in
atrium.lib.render registry // { sourceRegistry = registry; }
