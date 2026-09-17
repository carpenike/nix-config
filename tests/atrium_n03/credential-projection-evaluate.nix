{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = import ./pre-adoption.nix { inherit inputs; };
  baseline = forge.config;
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  units = [ "atrium-resolver" "atrium-device-registration" ];
  modelUnits = {
    atrium-model-resolver-initialize = {
      user = "atrium-resolver";
      names = [ "model-management" ];
      sources = [ "model-management:/run/secrets/atrium-litellm-resolver-management" ];
    };
    atrium-model-controller-initialize = {
      user = "atrium-reconciler";
      names = [ "management" ];
      sources = [ "management:/run/secrets/atrium-litellm-controller-management" ];
    };
    atrium-reconciler = {
      user = "atrium-reconciler";
      names = [ "family-anthropic" "management" "personal-anthropic" ];
      sources = [
        "family-anthropic:/run/secrets/atrium-family-anthropic"
        "management:/run/secrets/atrium-litellm-controller-management"
        "personal-anthropic:/run/secrets/atrium-personal-anthropic"
      ];
    };
  };
  nativeUnits = {
    atrium-native-policy = {
      user = "atrium-resolver";
      credentials = runtime.policyCredentials;
      rendererDirectories = [ "atrium-native-policy" ];
    };
    atrium-native-settings = {
      user = "homelab-mcp";
      credentials = lib.getAttrs [ "native-profile" "resolver-client-cert" ] runtime.nativeCredentials;
      rendererDirectories = [ "atrium-native-mcp" ];
    };
    homelab-mcp = {
      user = "homelab-mcp";
      credentials = runtime.nativeCredentials;
      rendererDirectories = [ ];
    };
  };
  deviceNames = builtins.attrNames runtime.deviceCredentials;
  variants = lib.cartesianProduct { native = [ false true ]; models = [ false true ]; };
  configured = flags: (forge.extendModules {
    modules = [{
      services.atriumForge.adoption = lib.mapAttrs (_: lib.mkForce) flags;
    }];
  }).config;
  document = config: unit:
    builtins.fromJSON config.environment.etc."atrium/runtime/${unit}.json".text;
  consumers = settings:
    (map (field: settings.devices.${field}) [
      "ca_certificate_path"
      "ca_private_key_path"
      "server_certificate_path"
      "server_private_key_path"
    ])
    ++ lib.optionals (settings.home_mcp != null)
      (map (field: settings.home_mcp.deployments.home-mcp.${field}) [
        "ca_certificate_path"
        "client_certificate_path"
        "client_private_key_path"
        "verification_keys_path"
      ])
    ++ lib.optional (settings.litellm != null) settings.litellm.controller_key_file;
  sorted = lib.sort builtins.lessThan;
  modelConsumers = config: unit:
    let
      settings = name: builtins.fromJSON config.environment.etc."atrium/${name}.json".text;
      providers = config.services.atrium.registry.serviceCredentials;
    in
    if unit == "atrium-model-resolver-initialize" then
      [ (settings "bootstrap/model-resolver").litellm.controller_key_file ]
    else if unit == "atrium-model-controller-initialize" then
      [ (settings "bootstrap/model-controller").management_key_file ]
    else [
      (settings "runtime/model-controller").management_key_file
      providers."cc.personal.ryan.anthropic".runtimePath
      providers."cc.family.holt.anthropic".runtimePath
    ];
  checkModelUnit = config: unit:
    let
      service = config.systemd.services.${unit}.serviceConfig;
      expected = modelUnits.${unit};
    in
    service.LoadCredential == expected.sources
    && sorted (modelConsumers config unit) == sorted (map (projection.path unit) expected.names)
    && lib.all (name: lib.hasInfix (lib.escapeShellArg name) (lib.head service.ExecStartPre)) expected.names
    && service.RuntimeDirectory == "${unit}-credentials"
    && service.RuntimeDirectoryMode == "0700"
    && service.RuntimeDirectoryPreserve == "no"
    && service.User == expected.user && service.Group == expected.user
    && service.ProtectSystem == "strict"
    && lib.hasInfix "python -I -B" (lib.head service.ExecStartPre)
    && !(lib.elem "/run/credentials" (service.ReadWritePaths or [ ]));
  checkNativeUnit = config: unit:
    let
      service = config.systemd.services.${unit}.serviceConfig;
      expected = nativeUnits.${unit};
      names = builtins.attrNames expected.credentials;
    in
    service.LoadCredential == lib.mapAttrsToList
      (name: path: "${name}:${path}")
      expected.credentials
    && sorted (lib.toList service.RuntimeDirectory)
    == sorted ([ "${unit}-credentials" ] ++ expected.rendererDirectories)
    && service.RuntimeDirectoryMode == "0700"
    && service.RuntimeDirectoryPreserve == "no"
    && service.User == expected.user && service.Group == expected.user
    && service.ProtectSystem == "strict"
    && lib.hasInfix "python -I -B" (lib.head service.ExecStartPre)
    && lib.hasInfix "credential-projection.py" (lib.head service.ExecStartPre)
    && lib.all
      (name: lib.hasInfix (lib.escapeShellArg name) (lib.head service.ExecStartPre))
      names
    && !(lib.elem "/run/credentials" (service.ReadWritePaths or [ ]));
  variantChecks = flags:
    let
      config = configured flags;
      checkUnit = unit:
        let
          service = config.systemd.services.${unit}.serviceConfig;
          paths = consumers (document config unit);
          names = map (value: builtins.head (lib.splitString ":" value)) service.LoadCredential;
          expected = deviceNames
            ++ lib.optionals (unit == "atrium-resolver" && flags.native)
            (builtins.attrNames runtime.brokerCredentials)
            ++ lib.optional (unit == "atrium-resolver" && flags.models) "model-management";
        in
        sorted names == sorted expected
        && sorted paths == sorted (map (projection.path unit) expected)
        && lib.all (name: lib.hasInfix (lib.escapeShellArg name) (lib.last service.ExecStartPre)) names
        && service.RuntimeDirectory == "${unit}-credentials"
        && service.RuntimeDirectoryMode == "0700"
        && service.RuntimeDirectoryPreserve == "no"
        && service.User == "atrium-resolver" && service.Group == "atrium-resolver"
        && service.ProtectSystem == "strict"
        && config.users.users.atrium-resolver.uid == 1060
        && !(lib.elem "/run/credentials" (service.ReadWritePaths or [ ]));
    in
    lib.all checkUnit units
    && lib.all (checkModelUnit config)
      ([ "atrium-model-resolver-initialize" "atrium-model-controller-initialize" ]
      ++ lib.optional flags.models "atrium-reconciler")
    && (if flags.native then
      lib.all (checkNativeUnit config) (builtins.attrNames nativeUnits)
    else
      !(config.systemd.services ? atrium-native-policy)
      && !(config.systemd.services ? atrium-native-settings)
      && config.systemd.services.homelab-mcp.serviceConfig
      == baseline.systemd.services.homelab-mcp.serviceConfig
      && config.systemd.services.homelab-mcp.environment
      == baseline.systemd.services.homelab-mcp.environment);
  rejectedFor = unit: credentials: !(builtins.tryEval (builtins.deepSeq
    (projection.serviceConfig {
      pkgs = baseline.nixpkgs.pkgs;
      inherit unit credentials;
    })
    true)).success;
  rejected = rejectedFor "atrium-resolver";
  modelCredentials = {
    management = "/run/secrets/atrium-litellm-controller-management";
    personal-anthropic = "/run/secrets/atrium-personal-anthropic";
    family-anthropic = "/run/secrets/atrium-family-anthropic";
  };
  native = (configured { native = true; models = false; }).systemd.services;
  nativePolicy = native.atrium-native-policy.serviceConfig;
  nativeSettings = native.atrium-native-settings.serviceConfig;
  nativeService = native.homelab-mcp.serviceConfig;
  nativePaths = [
    runtime.native.profile_path
    runtime.native.issuance.resolver_jwks
    runtime.native.issuance.tls.server_certificate
    runtime.native.issuance.tls.server_private_key
    runtime.native.issuance.tls.client_ca
    runtime.native.policy.resolver_jwks
    runtime.native.policy.ca_certificate_path
    runtime.native.policy.client_certificate_path
    runtime.native.policy.client_private_key_path
    runtime.native.deny.ca_bundle
  ];
  checks = {
    all-foundation-model-and-native-units-match-projection = lib.all variantChecks variants;
    unchanged-device-sources = lib.all
      (unit: baseline.systemd.services.${unit}.serviceConfig.LoadCredential
        == lib.mapAttrsToList (name: path: "${name}:${path}") runtime.deviceCredentials)
      units;
    unknown-name-refused = rejected (runtime.deviceCredentials // { unexpected = "/run/secrets/unexpected"; });
    incomplete-device-set-refused = rejected (builtins.removeAttrs runtime.deviceCredentials [ "device-ca-key" ]);
    incomplete-native-set-refused = rejected (runtime.deviceCredentials // { inherit (runtime.brokerCredentials) native-ca; });
    unknown-unit-refused = rejectedFor "atrium-unexpected" modelCredentials;
    resolver-initializer-controller-key-refused = rejectedFor "atrium-model-resolver-initialize"
      { inherit (modelCredentials) management; };
    controller-initializer-provider-key-refused = rejectedFor "atrium-model-controller-initialize"
      modelCredentials;
    empty-controller-initializer-refused = rejectedFor "atrium-model-controller-initialize" { };
    incomplete-provider-set-refused = rejectedFor "atrium-reconciler"
      (builtins.removeAttrs modelCredentials [ "family-anthropic" ]);
    reconciler-resolver-key-refused = rejectedFor "atrium-reconciler"
      (modelCredentials // { model-management = "/run/secrets/atrium-litellm-resolver-management"; });
    incomplete-native-unit-sets-refused = lib.all
      (unit: rejectedFor unit (builtins.removeAttrs nativeUnits.${unit}.credentials
        [ (lib.head (builtins.attrNames nativeUnits.${unit}.credentials)) ]))
      (builtins.attrNames nativeUnits);
    native-unrelated-environment-secret-refused = lib.all
      (unit: rejectedFor unit (nativeUnits.${unit}.credentials // {
        environment = "/run/secrets/homelab-mcp/env";
      }))
      (builtins.attrNames nativeUnits);
    native-model-credentials-refused = lib.all
      (unit: rejectedFor unit modelCredentials)
      (builtins.attrNames nativeUnits);
    native-cross-role-sets-refused =
      rejectedFor "atrium-native-policy" runtime.nativeCredentials
      && rejectedFor "homelab-mcp" runtime.policyCredentials
      && rejectedFor "atrium-native-settings" runtime.nativeCredentials;
    current-client-admission-preserved =
      baseline.services.atriumForge.groupEvidence.clientIds == [ "cc.atrium.operator" ]
      && (builtins.head (document baseline "atrium-resolver").authorities).group_evidence.client_ids
      == [ "cc.atrium.operator" ];
    adoption-remains-explicit = lib.all (value: !value)
      (builtins.attrValues baseline.services.atriumForge.adoption);
    identity-and-state-preserved = lib.all
      (unit:
        let settings = document baseline unit;
        in settings.state_directory == "/var/lib/atrium-resolver"
          && settings.signing.directory == "/var/lib/atrium-resolver/signing"
          && settings.signing.issuer == "https://atrium.holthome.net"
          && (builtins.head settings.authorities).issuer == "https://id.holthome.net"
          && (builtins.head settings.authorities).audience == "https://atrium.holthome.net/resolver")
      units;
    native-policy-consumers-match-projection =
      (map (field: runtime.nativePolicyTemplate.native_policy.${field}) [
        "server_certificate_path"
        "server_private_key_path"
        "client_ca_path"
      ]) == map (projection.path "atrium-native-policy")
        [ "policy-server-cert" "policy-server-key" "policy-client-ca" ];
    native-consumers-match-projection = nativePaths == map (projection.path "homelab-mcp") [
      "native-profile"
      "resolver-jwks"
      "server-cert"
      "server-key"
      "resolver-client-ca"
      "resolver-jwks"
      "policy-ca"
      "policy-client-cert"
      "policy-client-key"
      "public-ca"
    ];
    native-renderer-order-and-paths =
      lib.length nativePolicy.ExecStartPre == 2
      && lib.hasInfix
        "--client-certificate ${projection.path "atrium-native-policy" "policy-client-cert"}"
        (lib.last nativePolicy.ExecStartPre)
      && lib.hasInfix "--output /run/atrium-native-policy/settings.json"
        (lib.last nativePolicy.ExecStartPre)
      && lib.hasInfix "--config /run/atrium-native-policy/settings.json"
        nativePolicy.ExecStart
      && lib.length nativeSettings.ExecStartPre == 1
      && lib.hasInfix "--profile ${projection.path "atrium-native-settings" "native-profile"}"
        nativeSettings.ExecStart
      && lib.hasInfix
        "--client-certificate ${projection.path "atrium-native-settings" "resolver-client-cert"}"
        nativeSettings.ExecStart
      && lib.hasInfix "--output /run/atrium-native-mcp/native.env" nativeSettings.ExecStart
      && nativeSettings.RemainAfterExit && nativeSettings.PrivateNetwork
      && lib.elem "homelab-mcp.service" native.atrium-native-settings.partOf
      && lib.all
        (unit: lib.elem unit native.homelab-mcp.requires && lib.elem unit native.homelab-mcp.after)
        [ "firewall.service" "atrium-native-settings.service" "atrium-native-policy.service" ];
    native-existing-environment-preserved =
      nativeService.EnvironmentFile
      == baseline.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile
      ++ [ "/run/atrium-native-mcp/native.env" ];
    native-state-and-hardening-preserved = lib.all
      (field: nativeService.${field}
        == baseline.systemd.services.homelab-mcp.serviceConfig.${field})
      [
        "User"
        "Group"
        "StateDirectory"
        "StateDirectoryMode"
        "ReadWritePaths"
        "ProtectSystem"
        "ProtectHome"
        "PrivateTmp"
        "PrivateDevices"
        "NoNewPrivileges"
        "CapabilityBoundingSet"
        "SystemCallFilter"
        "MemoryDenyWriteExecute"
        "RestrictAddressFamilies"
        "ExecStart"
      ];
    native-signing-and-refresh-paths-preserved =
      native.homelab-mcp.environment.HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH
      == "/var/lib/homelab-mcp/signing-key.pem"
      && native.homelab-mcp.environment.HOMELAB_MCP_OAUTH_STATE_DB_PATH
      == "/var/lib/homelab-mcp/state.db"
      && runtime.native.deny.state_directory == "/var/lib/homelab-mcp/denial";
    native-adoption-still-required = lib.all
      (unit: lib.elem "/var/lib/atrium-policy/native-adoption.approved"
        native.${unit}.unitConfig.AssertFileNotEmpty)
      (builtins.attrNames nativeUnits);
    model-initializers-remain-manual = lib.all
      (unit:
        let service = baseline.systemd.services.${unit};
        in service.wantedBy == [ ] && service.requiredBy == [ ]
          && service.serviceConfig.PrivateNetwork
          && !(builtins.hasAttr unit baseline.systemd.timers))
      [ "atrium-model-resolver-initialize" "atrium-model-controller-initialize" ];
    model-identities-remain-separated =
      baseline.users.users.atrium-resolver.uid == 1060
      && baseline.users.users.atrium-reconciler.uid == 1063;
    no-automatic-key-generation = lib.all
      (unit: !lib.elem "atrium-trust-initialize.service" baseline.systemd.services.${unit}.requires)
      units;
    bytecode-disabled = lib.all
      (unit: lib.hasInfix "python -I -B" (lib.last baseline.systemd.services.${unit}.serviceConfig.ExecStartPre))
      units;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium credential projection wiring failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.forge-credential-projection-wiring";
  source_sha256 = builtins.hashFile "sha256" ../../hosts/forge/atrium/credential-projection.py;
  real_systemd_executed = false;
  live_operations = false;
}
