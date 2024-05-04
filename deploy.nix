{
  self,
  deploy-rs,
  ...
}:
let
  deployConfig = name: system: cfg: {
    hostname = "${name}.holthome.net";
    sshOpts = cfg.sshOpts or ["-A"];

    profiles = {
      system = {
        inherit (cfg) sshUser;
        path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${name};
        user = "root";
      };
    };

    remoteBuild = cfg.remoteBuild or false;
    autoRollback = cfg.autoRollback or false;
    magicRollback = cfg.magicRollback or true;
  };
in
{
  deploy.nodes = {
    rydev = deployConfig "rydev" "aarch64-linux" {sshUser = "ryan"; remoteBuild = true;};
  };
  checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
}