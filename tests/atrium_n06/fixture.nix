{ atrium }:
let
  base = (import ../atrium_n04/fixture.nix { inherit atrium; }).sourceRegistry;
  lib = atrium.inputs.nixpkgs.lib;
  imageHosts = {
    openai = "api.openai.com";
    gemini = "generativelanguage.googleapis.com";
    openrouter = "openrouter.ai";
  };
  registry = lib.recursiveUpdate base {
    providers = {
      fixture-model.egressHosts = [ "personal.models.atrium.invalid" "family.models.atrium.invalid" ];
    } // lib.mapAttrs (_: host: { egressHosts = [ host ]; }) imageHosts;
    serviceCredentials = {
      personal-model.runtimePath = "/run/atrium-n06/providers/personal-model";
      family-model.runtimePath = "/run/atrium-n06/providers/family-model";
    } // lib.mapAttrs'
      (provider: _: lib.nameValuePair "whiskey-${provider}" {
        runtimePath = "/run/atrium-n06/credentials/${provider}";
      })
      imageHosts;
    modelTemplates.whiskey-service = {
      routes = [ "/v1/messages" ];
      service = {
        runtimeKeyPath = "/run/atrium-n06/delivery/key.json";
        rotationIntervalSeconds = 2;
        overlapSeconds = 5;
      };
    };
    providerExceptions = lib.mapAttrs'
      (provider: host: lib.nameValuePair "whiskey-${provider}-image" {
        egress = {
          enforcement = "ip";
          hosts = [ host ];
          policyRef = "atrium-n06-isolated-address-policy";
        };
      })
      imageHosts;
  };
  rendered = atrium.lib.render registry;
  destination = kind: hosts: { inherit kind hosts; ports = [ 443 ]; };
  providerDestinations = lib.mapAttrs'
    (_: exception: lib.nameValuePair exception.provider
      (destination "provider-exception" exception.egress.hosts))
    registry.providerExceptions;
in
rendered // {
  sourceRegistry = registry;
  egress = {
    schema_version = 1;
    isolated = true;
    service_uid = 11001;
    destinations = {
      gateway = destination "gateway" [ "litellm.atrium.invalid" ];
      identity = destination "non-model" [ "identity.atrium.invalid" ];
      partiful = destination "non-model" [
        "api.partiful.com"
        "securetoken.googleapis.com"
        "firestore.googleapis.com"
        "calendar.atrium.invalid"
      ];
      media = destination "non-model" [ "media.atrium.invalid" ];
      plex = destination "non-model" [ "plex.atrium.invalid" ];
      cooklang = destination "non-model" [ "cooklang.atrium.invalid" ];
      mail = destination "non-model" [ "mail.atrium.invalid" ];
      webpush = destination "non-model" [ "push.atrium.invalid" ];
    } // providerDestinations;
  };
}
