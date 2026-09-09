{ inputs, enableModels ? false }:
let
  inherit (inputs) atrium;
  inherit (inputs.nixpkgs) lib;
  ids = lib.getAttrs [
    "atrium-reconciler-fixture"
    "atrium-consumer-fixture"
    "atrium-resolver-fixture"
    "atrium-caddy-fixture"
    "atrium-mcp-fixture"
    "atrium-identity-fixture"
    "atrium-client-fixture"
    "atrium-forwarder-fixture"
    "atrium-model-gateway-fixture"
    "atrium-model-metadata-fixture"
  ]
    (import ../../lib/service-uids.nix { });
  runtime = "/run/atrium-n03";
  port = 18443;
  nativePolicyPort = 18767;
  nativePolicyEndpoint = "https://127.0.0.1:${toString nativePolicyPort}/v1/native-policy";
  frontAddress = "198.19.3.2";
  names = {
    resolver = "atrium.atrium.invalid";
    native = "home-mcp.atrium.invalid";
    whiskey = "whiskey.atrium.invalid";
    models = "litellm.atrium.invalid";
    identity = "identity.atrium.invalid";
    registration = "registration.atrium.invalid";
  };
  origin = name: "https://${name}:${toString port}";
  endpoints = lib.mapAttrs (_: origin) names;
  credential = unit: name: "/run/credentials/${unit}.service/${name}";
  base = import ../../hosts/forge/atrium/registry-isolated.nix { inherit atrium; };
  registry = lib.recursiveUpdate base {
    authorities.pocket-id-fixture = {
      issuer = endpoints.identity;
      jwksUri = "${endpoints.identity}/.well-known/jwks.json";
    };
    catalogs.home-mcp-fixture.source =
      inputs.homelab-mcp + "/tests/fixtures/atrium_m03_catalog.generated.json";
    deployments = {
      home-mcp.endpoint = endpoints.native;
      whiskey.endpoint = endpoints.whiskey;
      litellm.endpoint = endpoints.models;
    };
    instances = {
      family-home-public = base.instances.family-home-admin // {
        route = "/mcp";
        displayName = "Family wing native public entry";
        scopes = [ "admin" "fixture.read" ];
        acl = base.instances.family-home-child.acl;
      };
      family-home-adults.scopes = [ "hermes" ];
    };
    routeTemplates = {
      family-public = base.routeTemplates.family-admin // {
        instance = "family-home-public";
      };
      family-public-read = base.routeTemplates.family-child-view // {
        instance = "family-home-public";
      };
      family-adults.scopes = [ "hermes" ];
    };
    serviceCredentials = lib.mapAttrs
      (name: _: { runtimePath = "${runtime}/provider-input/${name}"; })
      base.serviceCredentials;
    providers.fixture-model.egressHosts = [
      "personal.models.atrium.invalid"
      "family.models.atrium.invalid"
    ];
    modelBackends = {
      personal-text.model = "openai/fixture-personal";
      family-child.model = "openai/fixture-family";
    };
    modelTemplates.whiskey-service = {
      routes = [ "/v1/messages" ];
      maxLifetimeSeconds = 600;
      service = {
        runtimeKeyPath = "${runtime}/delivery/whiskey-service.json";
        rotationIntervalSeconds = 2;
        overlapSeconds = 5;
      };
    };
    providerExceptions = lib.mapAttrs
      (_: _: {
        egress = {
          enforcement = "ip";
          policyRef = "atrium-n03-isolated-address-policy";
        };
      })
      base.providerExceptions;
  };
  generated = atrium.lib.render registry;
  publishers = import ./publishers.nix { inherit inputs; };
  state = {
    resolver = "/var/lib/atrium-resolver";
    native = "/var/lib/homelab-mcp";
    whiskey = "/var/lib/whiskey-whiskey-whiskey";
  };
  resolverConfig = unit: {
    schema_version = 1;
    isolated_harness = true;
    state_directory = state.resolver;
    policy_path = "/etc/atrium/desired-state/resolver.json";
    group_authority = "pocket-id-fixture";
    authorities = lib.mapAttrsToList
      (id: value: {
        inherit id;
        inherit (value) issuer audience jwks_uri;
      })
      generated.resolver.authorities;
    signing = {
      directory = "${state.resolver}/signing";
      issuer = endpoints.resolver;
    };
    devices = {
      ca_certificate_path = credential unit "device-ca";
      ca_private_key_path = credential unit "device-ca-key";
      server_certificate_path = credential unit "registration-cert";
      server_private_key_path = credential unit "registration-key";
      certificate_lifetime_seconds = 900;
      max_challenges_per_principal = 32;
    };
    home_mcp.deployments.home-mcp = {
      endpoint = "${endpoints.native}/cc/issue";
      ca_certificate_path = credential unit "native-ca";
      client_certificate_path = credential unit "native-client-cert";
      client_private_key_path = credential unit "native-client-key";
      verification_keys_path = credential unit "native-jwks";
      timeout_seconds = 5;
    };
    # Distinct-UID live publication sharing must be supplied by the real producers.
    # Do not replace it with a root/chown relay, stale credential snapshot or shared signer UID.
    litellm = null;
  };
  nativeResource = generated.resolver.instances.family-home-public;
  nativePolicyConfig = (resolverConfig "atrium-native-policy") // {
    devices = null;
    home_mcp = null;
    native_policy = {
      audience = nativePolicyEndpoint;
      server_certificate_path = credential "atrium-native-policy" "policy-server-cert";
      server_private_key_path = credential "atrium-native-policy" "policy-server-key";
      client_ca_path = credential "atrium-native-policy" "policy-client-ca";
      adapters = [{
        id = "homelab-mcp-fixture";
        native_issuer = endpoints.native;
        deployment = "home-mcp";
        authorities.pocket-id-fixture = "atrium-n03-native";
        views = builtins.attrNames (lib.filterAttrs
          (_: instance: instance.status == "active" && instance.adapter == "home-mcp"
            && instance.deployment == "home-mcp")
          generated.resolver.instances);
        # Runtime PKI provisioning must fill the actual public leaf fingerprint.
        certificates = [ ];
      }];
    };
  };
in
{
  inherit registry generated runtime port frontAddress names endpoints state ids nativePolicyPort nativePolicyEndpoint;
  namespacePath = "/run/atrium-n03/netns";
  modelPlaneReady = enableModels && publishers.verified;
  modelPlaneBlocker = "explicit-native-opt-in-and-authorization-required";
  models = import ./models.nix {
    inherit lib ids runtime state registry generated endpoints publishers;
  };
  versions = {
    atrium = "7e8355d99efd4e94cf3dade1533e647a77ee7402";
    native = "338cbbdb990a5751d199f276c5d65b07730cd97d";
    consumer = "273cf414cac75276492ee849bb3ea257ce47f8de";
    litellm = "ghcr.io/berriai/litellm:v1.99.1@sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c";
  };
  resolver = (resolverConfig "atrium-resolver") // {
    litellm =
      if enableModels then (import ./models.nix {
        inherit lib ids runtime state registry generated endpoints publishers;
      }).resolver else null;
  };
  registration = resolverConfig "atrium-device-registration";
  nativePolicy = nativePolicyConfig;
  registrationPort = 19443;
  native = {
    resource = {
      id = nativeResource.id;
      inherit (nativeResource) domain audience target;
    };
    issuance = {
      resolver_issuer = endpoints.resolver;
      resolver_jwks = credential "homelab-mcp" "resolver-jwks";
      policy_path = "/etc/atrium/desired-state/resolver.json";
      tls = {
        server_certificate = credential "homelab-mcp" "server-cert";
        server_private_key = credential "homelab-mcp" "server-key";
        client_ca = credential "homelab-mcp" "resolver-client-ca";
      };
    };
    deny = {
      issuer = endpoints.resolver;
      feed_url = "${endpoints.resolver}/v1/deny-feed";
      jwks_url = "${endpoints.resolver}/.well-known/jwks.json";
      ca_bundle = credential "homelab-mcp" "front-ca";
      state_directory = "${state.native}/denial";
    };
    policy = {
      endpoint = nativePolicyEndpoint;
      authority = "pocket-id-fixture";
      resolver_issuer = endpoints.resolver;
      resolver_jwks = credential "homelab-mcp" "resolver-jwks";
      ca_certificate_path = credential "homelab-mcp" "policy-ca";
      client_certificate_path = credential "homelab-mcp" "policy-client-cert";
      client_private_key_path = credential "homelab-mcp" "policy-client-key";
      timeout_seconds = 5;
    };
  };
  whiskey = {
    schema_version = 1;
    issuer = endpoints.resolver;
    jwks_uri = "${endpoints.resolver}/.well-known/jwks.json";
    native_issuer = endpoints.identity;
    authority = "pocket-id-fixture";
    domain = "personal:ryan";
    instance_id = "personal-whiskey";
    target = generated.resolver.instances.personal-whiskey.target;
    isolated_harness = true;
    deny = {
      feed_uri = "${endpoints.resolver}/v1/deny-feed";
      state_directory = "${state.whiskey}/atrium-admission";
    };
  };
  whiskeyModel = {
    schema_version = 1;
    installation = "atrium-n03-isolated";
    issuer = endpoints.models;
    model = "cc.personal.ryan.text";
    template_id = "whiskey-service";
    key_path = registry.modelTemplates.whiskey-service.service.runtimeKeyPath;
    key_owner_uid = ids.atrium-reconciler-fixture.uid;
    acknowledgement_path = "${runtime}/acknowledgements/whiskey/key.json";
    isolated_harness = true;
  };
  egress = {
    schema_version = 1;
    isolated = true;
    service_uid = ids.atrium-consumer-fixture.uid;
    destinations = {
      gateway = { kind = "gateway"; hosts = [ names.models ]; ports = [ port ]; };
      identity = { kind = "non-model"; hosts = [ names.identity ]; ports = [ port ]; };
      deny-feed = { kind = "non-model"; hosts = [ names.resolver ]; ports = [ port ]; };
    } // lib.mapAttrs'
      (_: exception: lib.nameValuePair exception.provider {
        kind = "provider-exception";
        hosts = exception.egress.hosts;
        ports = [ port ];
      })
      registry.providerExceptions;
  };
}
