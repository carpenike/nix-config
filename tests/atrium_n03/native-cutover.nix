{ pkgs, resolverPackage, nativePackage, nativeCatalog, atrium, hostPkgs ? pkgs }:
let
  inherit (pkgs) lib;
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  ids = import ../../lib/service-uids.nix { };
  nativeIdentity = lib.getAttrs [ "uid" "gid" ] ids.atrium-mcp-fixture;
  resolverIdentity = lib.getAttrs [ "uid" "gid" ] ids.atrium-resolver-fixture;
  trustIdentity = lib.getAttrs [ "uid" "gid" ] ids.atrium-identity-fixture;
  python = pkgs.python313.withPackages (ps: [ (ps.toPythonModule nativePackage) ]);
  root = "/run/atrium-native-cutover-fixture";
  nativeIssuer = "https://native.atrium.invalid:18443";
  resolverIssuer = "https://resolver.atrium.invalid:18443";
  installation = "atrium-native-cutover-fixture";
  principal = "fixture-owner";
  authority = "fixture-pocket-id";
  domain = "personal:fixture-owner";
  views = {
    personal-data-read = { route = "/mcp"; scope = "atrium-personal-read"; access = "read-only"; };
    personal-finance = { route = "/cc/views/personal-finance"; scope = "atrium-personal-finance"; access = "read-write"; };
    personal-scribe = { route = "/cc/views/personal-scribe"; scope = "atrium-personal-scribe"; access = "read-write"; };
    personal-status = { route = "/cc/views/personal-status"; scope = "atrium-personal-status"; access = "read-only"; };
  };
  registry = {
    environment = "isolated";
    domains.${domain}.displayName = "Synthetic Personal wing";
    teams."cc.fixture.native" = {
      inherit domain;
      owner = "command-center";
      models = [ "cc.fixture.native.unused" ];
    };
    # N02 requires a domain-owned team/alias. No model service, credential or
    # provider request is instantiated by this native-only guest.
    aliases."cc.fixture.native.unused" = {
      inherit domain;
      owner = "command-center";
      team = "cc.fixture.native";
      backends = [ "unused-fixture" ];
    };
    providers.unused-fixture.egressHosts = [ "unused-provider.atrium.invalid" ];
    modelBackends.unused-fixture = {
      inherit domain;
      provider = "unused-fixture";
      account = "synthetic-never-contacted";
      credential = "unused-fixture";
      model = "fixture/never-contacted";
    };
    serviceCredentials.unused-fixture = {
      inherit domain;
      principal = "fixture-model-service";
      provider = "unused-fixture";
      account = "synthetic-never-contacted";
      runtimePath = "${root}/never-provisioned-provider-key";
    };
    authorities.${authority} = {
      kind = "synthetic";
      issuer = "https://identity.atrium.invalid";
      audience = "atrium-native-cutover-fixture";
      jwksUri = "https://identity.atrium.invalid/jwks";
      tokenType = "access_token";
    };
    principals = {
      ${principal} = {
        displayName = "Synthetic owner";
        kind = "human";
        roles = [ "admin" ];
        bindings = [{ inherit authority; subject = "synthetic-owner-subject"; }];
      };
      fixture-model-service = {
        displayName = "Unused synthetic provider owner";
        kind = "service";
        roles = [ ];
        bindings = [ ];
      };
    };
    catalogs.home-mcp = {
      adapter = "home-mcp";
      # Keep the source-exported path: the package's filtered src need not be
      # materialized during `flake check --no-build`.
      source = nativeCatalog;
    };
    deployments.home-mcp = {
      adapter = "home-mcp";
      endpoint = nativeIssuer;
      catalog = "home-mcp";
      viewEnforcement = "server-dispatch";
    };
    instances = lib.mapAttrs
      (_: view: {
        inherit domain;
        inherit (view) route access;
        ownerPrincipal = principal;
        deployment = "home-mcp";
        affinity = "remote";
        kind = "view";
        displayName = "Synthetic cutover view";
        audience = "home-mcp";
        authorityBinding = [ authority ];
        acl.principals = [ principal ];
        deviceAcl.mode = "agnostic";
        scopes = [ view.scope ];
        permissions = [ ];
      })
      views;
    routeTemplates = lib.mapAttrs'
      (name: view: lib.nameValuePair "cc.fixture.${name}" {
        inherit domain;
        instance = name;
        scopes = [ view.scope ];
        permissions = [ ];
        acl.principals = [ principal ];
        maxLifetimeSeconds = 900;
      })
      views;
  };
  generated = atrium.lib.render registry;
  jsonFile = name: value: pkgs.writeText name (builtins.toJSON value);
  policy = jsonFile "native-cutover-fixture-policy.json" generated.resolver;
  enrollment = {
    schema_version = 1;
    principals = lib.mapAttrsToList
      (id: value: {
        inherit id;
        inherit (value) kind roles;
        display_name = value.displayName;
      })
      registry.principals;
    identities = [{ inherit principal authority; subject = "synthetic-owner-subject"; }];
  };
  resolverConfig = {
    schema_version = 1;
    isolated_harness = true;
    state_directory = "${root}/resolver";
    policy_path = policy;
    group_authority = authority;
    authorities = lib.mapAttrsToList
      (id: value: { inherit id; inherit (value) issuer audience jwks_uri; })
      generated.resolver.authorities;
    signing = { directory = "${root}/resolver/signing"; issuer = resolverIssuer; };
  };
  seed = names: {
    schema_version = 1;
    administrator = principal;
    grants = map
      (name: {
        id = "cc.fixture.${name}.baseline";
        inherit principal authority;
        subject = "synthetic-owner-subject";
        expires_at = null;
        can_delegate = false;
        request = {
          inherit domain;
          instance = name;
          template_id = "cc.fixture.${name}";
          scopes = [ views.${name}.scope ];
          permissions = [ ];
          models = [ ];
          routes = [ ];
          budget = null;
          lifetime_seconds = 900;
        };
      })
      names;
  };
  nativeTemplate = runtime.native // {
    resource = {
      id = "personal-data-read";
      inherit domain;
      audience = "home-mcp";
      target = "${nativeIssuer}/mcp";
    };
    issuance = runtime.native.issuance // {
      resolver_issuer = resolverIssuer;
      policy_path = policy;
    };
    policy = runtime.native.policy // {
      inherit authority;
      resolver_issuer = resolverIssuer;
    };
    deny = {
      issuer = resolverIssuer;
      feed_url = "${resolverIssuer}/v1/deny-feed";
      jwks_url = "${resolverIssuer}/.well-known/jwks.json";
      ca_bundle = "${root}/native/public-ca.pem";
      state_directory = "${root}/native/denial";
    };
  };
  tlsPlan = runtime.tlsPlan // {
    directory = "${root}/trust";
    authorities = map (entry: entry // { common_name = "Synthetic ${entry.id}"; })
      runtime.tlsPlan.authorities;
    certificates = map
      (entry: entry // {
        common_name = "Synthetic ${entry.id}";
        names = lib.optionals (entry.purpose == "server")
          [ "native.atrium.invalid" "resolver.atrium.invalid" "127.0.0.1" ];
      })
      runtime.tlsPlan.certificates;
  };
  config = {
    schema_version = 1;
    inherit installation;
    native_template = jsonFile "native-cutover-fixture-native.json" nativeTemplate;
    resolver_config = jsonFile "native-cutover-fixture-resolver.json" resolverConfig;
    enrollment = jsonFile "native-cutover-fixture-enrollment.json" enrollment;
    tls_plan = jsonFile "native-cutover-fixture-tls-plan.json" tlsPlan;
    policy_directory = "${root}/policy";
    native_signing_key = "${root}/native/signing-key.pem";
    native_oauth_database = "${root}/native/state.db";
    native_identity = nativeIdentity;
    resolver_identity = resolverIdentity;
    trust_identity = trustIdentity;
    resolver_command = lib.getExe resolverPackage;
    native_bootstrap = ../../hosts/forge/atrium/native-bootstrap.py;
    native_bootstrap_config = jsonFile "native-cutover-fixture-deny.json" {
      inherit installation;
      native_issuer = nativeIssuer;
      inherit (nativeTemplate) deny;
    };
    finance_grants = jsonFile "native-cutover-fixture-finance.json"
      (seed [ "personal-finance" "personal-scribe" "personal-status" ]);
    native_issuer = nativeIssuer;
    native_jwks_url = "${nativeIssuer}/oauth/jwks.json";
    resolver_jwks_url = "${resolverIssuer}/.well-known/jwks.json";
    ca_bundle = "${root}/public-ca.pem";
  };
  configFile = jsonFile "native-cutover-fixture-config.json" config;
  fixture = jsonFile "native-cutover-fixture.json" {
    inherit root;
    config = configFile;
    helper = ../../hosts/forge/atrium/native-cutover.py;
    ordinary_grants = jsonFile "native-cutover-fixture-ordinary.json" (seed [ "personal-data-read" ]);
    foreign_identity = lib.getAttrs [ "uid" "gid" ] ids.atrium-client-fixture;
  };
  fixtureProgram = ./native-cutover-fixture.py;
in
hostPkgs.testers.runNixOSTest {
  name = "atrium-owner-native-cutover";
  globalTimeout = 600;
  node.pkgs = lib.mkForce pkgs;
  nodes.machine = {
    virtualisation = { memorySize = 1536; cores = 2; vlans = [ ]; };
    networking = {
      hostName = "atrium-native-cutover-fixture";
      useDHCP = false;
      hosts."127.0.0.1" = [ "native.atrium.invalid" "resolver.atrium.invalid" ];
    };
    users.groups = lib.genAttrs
      [ "atrium-mcp-fixture" "atrium-resolver-fixture" "atrium-identity-fixture" "atrium-client-fixture" ]
      (name: { inherit (ids.${name}) gid; });
    users.users = lib.genAttrs
      [ "atrium-mcp-fixture" "atrium-resolver-fixture" "atrium-identity-fixture" "atrium-client-fixture" ]
      (name: { isSystemUser = true; inherit (ids.${name}) uid; group = name; });
    system.stateVersion = "25.11";
  };
  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    result = json.loads(machine.succeed(
        "${python}/bin/python -I -B ${fixtureProgram} --fixture ${fixture}",
        timeout=540,
    ))
    assert result["kind"] == "atrium.native-cutover-fixture"
    assert result["native_oauth_history_preserved"]
    assert result["real_policy_and_deny_implementations"]
    assert not result["signers_rotated"] and not result["production_operations"]
    print(json.dumps(result, sort_keys=True))
  '';
}
