{ nixpkgs, atrium }:
let
  lib = nixpkgs.lib;
  fixture = import ./fixture.nix { inherit atrium; };
  eval = isolated: extraModules: lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      atrium.nixosModules.whiskey-egress-fixture
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
    ] ++ extraModules;
  };
  config = (eval true [ ]).config;
  consumer = config.systemd.services.atrium-whiskey-fixture;
  setup = config.systemd.services.atrium-whiskey-egress-fixture;
  compose = serviceConfig: (eval true [
    { systemd.services.atrium-whiskey-fixture = { inherit serviceConfig; }; }
  ]).config;
  emptyCapabilities = cfg:
    let service = cfg.systemd.services.atrium-whiskey-fixture.serviceConfig;
    in service.CapabilityBoundingSet == [ "" ] && service.AmbientCapabilities == [ "" ];
  privileged = compose {
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_ADMIN" ];
    AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_DAC_OVERRIDE" ];
  };
  defaultPrivileged = compose {
    CapabilityBoundingSet = lib.mkDefault [ "CAP_NET_ADMIN" ];
    AmbientCapabilities = lib.mkDefault [ "CAP_NET_RAW" ];
  };
  orderedPrivileged = compose {
    CapabilityBoundingSet = lib.mkBefore [ "CAP_SYS_ADMIN" ];
    AmbientCapabilities = lib.mkAfter [ "CAP_NET_ADMIN" ];
  };
  forcedPrivileged = compose {
    CapabilityBoundingSet = lib.mkForce [ "CAP_NET_ADMIN" ];
    AmbientCapabilities = lib.mkForce [ "CAP_SYS_ADMIN" ];
  };
  strongerPrivileged = compose {
    CapabilityBoundingSet = lib.mkOverride 0 [ "CAP_NET_RAW" ];
    AmbientCapabilities = lib.mkOverride 0 [ "CAP_DAC_OVERRIDE" ];
  };
  capabilityOverrideRejected = cfg: lib.any
    (entry:
      entry.message == "N06 consumer capability sets must remain empty after module composition."
      && !entry.assertion)
    cfg.assertions;
in
{
  registry_valid = builtins.isAttrs fixture.registry;
  image_exception_granularity = lib.all
    (exception: exception.egress.enforcement == "ip")
    (builtins.attrValues fixture.sourceRegistry.providerExceptions);
  publication_routes = fixture.litellm.model_templates.whiskey-service.routes == [ "/v1/messages" ];
  native_namespace_only = setup.serviceConfig.NetworkNamespacePath == "/run/atrium-n06/fixture/netns";
  bindings_reference = lib.hasInfix "/run/atrium-n06/fixture/bindings.json" setup.serviceConfig.ExecStart;
  namespace_identity_reference = lib.hasInfix "net:[12345]" setup.serviceConfig.ExecStart;
  nonroot_consumer = consumer.serviceConfig.User == "11001";
  cannot_change_filter = emptyCapabilities config && consumer.serviceConfig.NoNewPrivileges;
  inherited_capabilities_cleared = emptyCapabilities privileged;
  default_capabilities_cleared = emptyCapabilities defaultPrivileged;
  ordered_capabilities_cleared = emptyCapabilities orderedPrivileged;
  forced_capabilities_rejected = capabilityOverrideRejected forcedPrivileged;
  stronger_capabilities_rejected = capabilityOverrideRejected strongerPrivileged;
  rendered_capabilities_reset =
    let text = privileged.systemd.units."atrium-whiskey-fixture.service".text;
    in lib.hasInfix "CapabilityBoundingSet=\n" text
      && lib.hasInfix "AmbientCapabilities=\n" text;
  setup_keeps_namespace_capability = setup.serviceConfig.CapabilityBoundingSet == [ "CAP_NET_ADMIN" ];
  no_direct_anthropic_key = lib.elem "ANTHROPIC_API_KEY" consumer.serviceConfig.UnsetEnvironment;
  rotating_key_remains_live_path = consumer.environment.WWW_ATRIUM_MODEL_CONFIG == "/run/atrium-n06/consumer.json";
  isolated_only = lib.any (entry: !entry.assertion) (eval false [ ]).config.assertions;
}
