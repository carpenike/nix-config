{ ...
}:
{
  modules = {
    deployment.nix.enable = true;
    development.enable = true;
    # kubernetes.enable = true;  # Commented out - no longer using Kubernetes
    security.gnugpg.enable = true;

    # Bash config (mirrors forge): provides the www-prod-pat loader for
    # VS Code Copilot terminals, which run bash so the prompt doesn't
    # confuse Copilot's terminal parser. Keeps fish as the default
    # interactive shell for normal terminals.
    shell.bash = {
      enable = true;
      launchFishForInteractive = true;
    };
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
