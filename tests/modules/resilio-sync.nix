let
  system = "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  lib = pkgs.lib;
  nixosSystem = import (pkgs.path + "/nixos/lib/eval-config.nix");
  eval = nixosSystem {
    inherit system;
    modules = [
      ../../modules/nixos/services/resilio-sync/default.nix
      ({ ... }: {
        config.networking.hostName = "resilio-test";

        config.modules.services.resilioSync = {
          enable = true;
          afterUnits = [ "zfs-mount.service" "local-fs.target" "data.mount" ];
          wantUnits = [ "zfs-mount.service" "data.mount" ];
          folders = {
            cooklang = {
              path = "/data/cooklang/recipes";
              secretFile = "/run/secrets/resilio/cooklang";
              group = "cooklang";
              owner = "cooklang";
              ensurePermissions = true;
              mode = "2770";
              knownHosts = [ "nas-1.holthome.net:4444" ];
            };
            media = {
              path = "/data/media/config";
              secretFile = "/run/secrets/resilio/media";
              group = "media-indexer";
              owner = "media-indexer";
              ensurePermissions = false;
            };
            docs = {
              path = "/data/docs";
              secretFile = "/run/secrets/resilio/docs";
              group = "docs";
              owner = "docs";
              ensurePermissions = true;
              mode = "0750";
              readOnly = true;
            };
          };
        };
      })
    ];
  };

  sharedFolders = eval.config.services.resilio.sharedFolders;
  extraGroups = eval.config.users.users.rslsync.extraGroups;
  tmpfiles = eval.config.systemd.tmpfiles.rules;
  resilioAfter = eval.config.systemd.services.resilio.after;
  resilioWants = eval.config.systemd.services.resilio.wants;

  hasTmpfile = path: lib.any (rule: lib.hasPrefix "d ${path}" rule) tmpfiles;

in
assert (lib.assertMsg (lib.length sharedFolders == 3)
  "Resilio helper regression: expected three shared folders");
assert (lib.assertMsg
  (builtins.elem "/run/secrets/resilio/cooklang"
    (map (folder: folder.secretFile) sharedFolders))
  "Cooklang secret file path not propagated");
assert (lib.assertMsg (lib.length extraGroups == 3)
  "rslsync extraGroups should contain exactly three entries");
assert (lib.assertMsg (lib.all (group: lib.elem group extraGroups) [ "cooklang" "media-indexer" "docs" ])
  "rslsync extraGroups did not include all service groups");
assert (lib.assertMsg (hasTmpfile "/data/cooklang/recipes")
  "tmpfiles rule missing for cooklang folder");
assert (lib.assertMsg (hasTmpfile "/data/docs")
  "tmpfiles rule missing for docs folder");
assert (lib.assertMsg (!hasTmpfile "/data/media/config")
  "tmpfiles rule unexpectedly generated for media folder");
assert (lib.assertMsg
  (lib.all (unit: lib.elem unit resilioAfter)
    [ "zfs-mount.service" "local-fs.target" "data.mount" ])
  "systemd after dependencies regressed");
assert (lib.assertMsg
  (lib.all (unit: lib.elem unit resilioWants)
    [ "zfs-mount.service" "data.mount" ])
  "systemd wants dependencies regressed");
{
  inherit sharedFolders extraGroups tmpfiles resilioAfter resilioWants;
}
