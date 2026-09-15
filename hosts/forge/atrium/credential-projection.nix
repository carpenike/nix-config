{ lib }:
let
  units = [ "atrium-resolver" "atrium-device-registration" ];
  deviceNames = [ "device-ca" "device-ca-key" "registration-cert" "registration-key" ];
  nativeNames = [ "native-ca" "native-client-cert" "native-client-key" "native-jwks" ];
  runtimeName = unit:
    assert lib.assertMsg (lib.elem unit units) "Only the two Atrium foundation listeners project credentials.";
    "${unit}-credentials";
  directory = unit: "/run/${runtimeName unit}";
in
{
  inherit directory;
  path = unit: name: "${directory unit}/material/${name}";
  serviceConfig = { pkgs, unit, credentials }:
    let
      names = builtins.attrNames credentials;
      allowed = deviceNames ++ lib.optionals (unit == "atrium-resolver")
        (nativeNames ++ [ "model-management" ]);
      nativeSelected = lib.filter (name: lib.elem name names) nativeNames;
    in
    assert lib.assertMsg
      (lib.all (name: lib.elem name names) deviceNames
        && lib.all (name: lib.elem name allowed) names
        && (nativeSelected == [ ] || lib.length nativeSelected == lib.length nativeNames))
      "Atrium credential projection requires the exact declared device/native/model credential sets.";
    {
      RuntimeDirectory = runtimeName unit;
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "no";
      ExecStartPre = [
        "${pkgs.python3}/bin/python -I -B ${./credential-projection.py} ${unit} ${lib.escapeShellArgs names}"
      ];
    };
}
