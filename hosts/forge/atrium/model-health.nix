{ pkgs, resolverDirectory, controllerDirectory, admission, settingsPath }:
let
  publications = [
    "${resolverDirectory}/associations.json"
    "${controllerDirectory}/native-bindings.json"
    "${controllerDirectory}/service-associations.json"
    "${controllerDirectory}/reconciliation.json"
  ];
in
''
  set -eu
  now=$(${pkgs.coreutils}/bin/date +%s)
  for path in ${pkgs.lib.escapeShellArgs publications}; do
    test -f "$path"
    test ! -L "$path"
    test -r "$path"
    timestamp=$(${pkgs.coreutils}/bin/stat -c %Y "$path")
    test "$timestamp" -le "$now"
    test "$((now - timestamp))" -le 80
  done
  ${admission} --settings ${pkgs.lib.escapeShellArg settingsPath} status >/dev/null
''
