let
  system = builtins.currentSystem;
  pkgs = import <nixpkgs> { inherit system; };
  lib = pkgs.lib;
  nixosSystem = import (pkgs.path + "/nixos/lib/eval-config.nix");
  testConfig = nixosSystem {
    inherit system;
    modules = [
      ../../modules/nixos/services/cooklang/default.nix
      ({ lib, ... }: {
        options.modules.storage = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        options.modules.backup = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        options.modules.notifications = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        options.modules.alerting = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        options.modules.services.caddy = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };

        config.networking.hostName = "cooklang-test";
        config.modules = {
          storage.datasets = {
            parentDataset = "tank/services";
            services = { };
          };
          backup.sanoid = {
            enable = false;
            datasets = { };
            replicationUser = "root";
            sshKeyPath = "/var/lib/zfs-replication/.ssh/id_ed25519";
          };
          notifications.enable = false;
          alerting = {
            enable = false;
            rules = { };
          };
          services = {
            caddy.virtualHosts = { };
          };
        };
        config.modules.services.cooklang = {
          enable = true;
          datasetPath = null;
          recipeDir = "/srv/cooklang";
          reverseProxy = {
            enable = true;
            hostName = "recipes.test";
          };
        };
      })
    ];
  };
  backend = testConfig.config.modules.services.cooklang.reverseProxy.backend;
in
assert lib.assertMsg (backend.host == "127.0.0.1") "Cooklang reverse proxy host default regressed";
assert lib.assertMsg (backend.port == 9080) "Cooklang reverse proxy port default regressed";
{
  inherit (backend) host port scheme;
}
