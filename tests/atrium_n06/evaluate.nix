{ nixpkgs, atrium }:
let
  lib = nixpkgs.lib;
  fixture = import ./fixture.nix { inherit atrium; };
  eval = isolated: lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      ./module.nix
      {
        system.stateVersion = "25.05";
        services.atriumWhiskeyEgressFixture = {
          enable = true;
          isolatedHarness = isolated;
          namespacePath = "/run/atrium-n06/fixture/netns";
          namespaceIdentity = "net:[12345]";
          bindingsFile = "/run/atrium-n06/fixture/bindings.json";
          modelConfigFile = "/run/atrium-n06/consumer.json";
          imageEnvironmentFile = "/run/atrium-n06/image-credentials.env";
          credentialPaths = [ "/run/atrium-n06/delivery" "/run/atrium-n06/credentials" ];
          policy = fixture.egress;
        };
        systemd.services.atrium-whiskey-fixture.serviceConfig.ExecStart = "${nixpkgs.legacyPackages.aarch64-linux.coreutils}/bin/true";
      }
    ];
  };
  config = (eval true).config;
  consumer = config.systemd.services.atrium-whiskey-fixture;
  setup = config.systemd.services.atrium-whiskey-egress-fixture;
in
{
  registry_valid = builtins.isAttrs fixture.registry;
  image_exception_granularity = lib.all
    (exception: exception.egress.enforcement == "ip")
    (builtins.attrValues fixture.sourceRegistry.providerExceptions);
  publication_routes = fixture.litellm.model_templates.whiskey-service.routes == [ "/v1/messages" ];
  native_namespace_only = setup.serviceConfig.NetworkNamespacePath == "/run/atrium-n06/fixture/netns";
  nonroot_consumer = consumer.serviceConfig.User == "11001";
  cannot_change_filter = consumer.serviceConfig.CapabilityBoundingSet == [ ] && consumer.serviceConfig.NoNewPrivileges;
  no_direct_anthropic_key = lib.elem "ANTHROPIC_API_KEY" consumer.serviceConfig.UnsetEnvironment;
  rotating_key_remains_live_path = consumer.environment.WWW_ATRIUM_MODEL_CONFIG == "/run/atrium-n06/consumer.json";
  isolated_only = lib.any (entry: !entry.assertion) (eval false).config.assertions;
}
