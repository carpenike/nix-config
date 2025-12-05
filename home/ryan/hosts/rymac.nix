{ ...
}:
{
  modules = {
    deployment.nix.enable = true;
    development.enable = true;
    kubernetes.enable = true;
    security.gnugpg.enable = true;
    security.ssh = {
      enable = true;
      matchBlocks = {
        "forge.holthome.net" = {
          forwardAgent = true;
          # Forward GPG agent socket to forge for commit signing
          # Remote path: /run/user/<uid>/gnupg/S.gpg-agent
          # Local path: ~/.gnupg/S.gpg-agent.extra (the "extra" socket for remote use)
          remoteForwards = [
            {
              bind.address = "/run/user/1000/gnupg/S.gpg-agent";
              host.address = "/Users/ryan/.gnupg/S.gpg-agent.extra";
            }
          ];
        };
      };
    };
  };
}
