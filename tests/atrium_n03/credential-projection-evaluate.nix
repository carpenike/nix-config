{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  baseline = forge.config;
  projection = import ../../hosts/forge/atrium/credential-projection.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  units = [ "atrium-resolver" "atrium-device-registration" ];
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
    lib.all checkUnit units;
  rejected = credentials: !(builtins.tryEval (builtins.deepSeq
    (projection.serviceConfig {
      pkgs = baseline.nixpkgs.pkgs;
      unit = "atrium-resolver";
      inherit credentials;
    })
    true)).success;
  checks = {
    all-foundation-consumers-match-projection = lib.all variantChecks variants;
    unchanged-device-sources = lib.all
      (unit: baseline.systemd.services.${unit}.serviceConfig.LoadCredential
        == lib.mapAttrsToList (name: path: "${name}:${path}") runtime.deviceCredentials)
      units;
    unknown-name-refused = rejected (runtime.deviceCredentials // { unexpected = "/run/secrets/unexpected"; });
    incomplete-device-set-refused = rejected (builtins.removeAttrs runtime.deviceCredentials [ "device-ca-key" ]);
    incomplete-native-set-refused = rejected (runtime.deviceCredentials // { inherit (runtime.brokerCredentials) native-ca; });
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
    unrelated-native-paths-unchanged =
      runtime.nativePolicyTemplate.native_policy.server_private_key_path
      == "/run/credentials/atrium-native-policy.service/policy-server-key"
      && runtime.native.issuance.tls.server_private_key
      == "/run/credentials/homelab-mcp.service/server-key";
    model-initializer-path-unchanged =
      (builtins.fromJSON baseline.environment.etc."atrium/bootstrap/model-resolver.json".text).litellm.controller_key_file
      == "/run/credentials/atrium-model-resolver-initialize.service/model-management";
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
