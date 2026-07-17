{ lib, ... }:

let
  discoverModules = directory:
    let
      entries = builtins.readDir directory;
    in
    lib.concatMap
      (name:
        let
          entryType = entries.${name};
          path = directory + "/${name}";
        in
        if entryType == "directory" then
          discoverModules path
        else
          lib.optional
            (entryType == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
            path)
      (builtins.attrNames entries);
in
{
  imports = discoverModules ./.;
}
