{ lib }:
let
  deviceNames = [ "device-ca" "device-ca-key" "registration-cert" "registration-key" ];
  nativeNames = [ "native-ca" "native-client-cert" "native-client-key" "native-jwks" ];
  credentialSets = {
    atrium-resolver = [
      deviceNames
      (deviceNames ++ nativeNames)
      (deviceNames ++ [ "model-management" ])
      (deviceNames ++ nativeNames ++ [ "model-management" ])
    ];
    atrium-device-registration = [ deviceNames ];
    atrium-model-resolver-initialize = [ [ "model-management" ] ];
    atrium-model-controller-initialize = [ [ "management" ] ];
    atrium-reconciler = [ [ "management" "personal-anthropic" "family-anthropic" ] ];
    atrium-native-policy = [
      [ "policy-server-cert" "policy-server-key" "policy-client-ca" "policy-client-cert" ]
    ];
    atrium-native-settings = [ [ "native-profile" "resolver-client-cert" ] ];
    homelab-mcp = [
      [
        "server-cert"
        "server-key"
        "resolver-client-ca"
        "resolver-client-cert"
        "resolver-jwks"
        "native-profile"
        "public-ca"
        "policy-ca"
        "policy-client-cert"
        "policy-client-key"
      ]
    ];
  };
  runtimeName = unit:
    assert lib.assertMsg (builtins.hasAttr unit credentialSets)
      "Only declared Atrium foundation, model and native units project credentials.";
    "${unit}-credentials";
  directory = unit: "/run/${runtimeName unit}";
in
{
  inherit directory;
  path = unit: name: "${directory unit}/material/${name}";
  serviceConfig = { pkgs, unit, credentials }:
    let
      names = builtins.attrNames credentials;
    in
    assert lib.assertMsg
      (builtins.hasAttr unit credentialSets
        && lib.elem names (map (lib.sort builtins.lessThan) credentialSets.${unit}))
      "Atrium credential projection requires the exact credential set declared for its unit.";
    {
      RuntimeDirectory = runtimeName unit;
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "no";
      ExecStartPre = [
        "${pkgs.python3}/bin/python -I -B ${./credential-projection.py} ${unit} ${lib.escapeShellArgs names}"
      ];
    };
}
