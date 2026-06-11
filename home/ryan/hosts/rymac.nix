{ pkgs
, config
, lib
, ...
}:
let
  # sops-nix (home-manager) decrypts to a runtime dir and symlinks into the
  # home; reference these paths so the shell loaders never hardcode them.
  keystorePasswordPath = config.sops.secrets."www-shield/keystore-password".path;
  keyPasswordPath = config.sops.secrets."www-shield/key-password".path;
in
{
  home.packages = with pkgs; [
    podman
    podman-compose
  ];

  # WWW Shield signing keystore.
  #
  # Non-secret values are exported for every shell via session variables.
  # The two passwords are decrypted by sops-nix (using my PGP key, which is a
  # recipient for every *.sops.yaml) and loaded into interactive shells below.
  # Add the password values with:  sops home/ryan/secrets.sops.yaml
  home.sessionVariables = {
    WWW_SHIELD_KEYSTORE = "/Users/ryan/src/material/www-shield-release.jks";
    WWW_SHIELD_KEY_ALIAS = "www-shield";
  };

  sops = {
    # rymac has no machine age key in .sops.yaml; decrypt with my PGP key.
    gnupg.home = "${config.home.homeDirectory}/.gnupg";
    defaultSopsFile = ../secrets.sops.yaml;
    secrets = {
      "www-shield/keystore-password" = { };
      "www-shield/key-password" = { };
    };
  };

  # Load the WWW Shield signing passwords into interactive shells. Guarded on
  # readability so a missing/locked secret never breaks shell startup.
  programs.bash.initExtra = lib.mkAfter ''
    if [[ -r "${keystorePasswordPath}" ]]; then
      export WWW_SHIELD_KEYSTORE_PASSWORD="$(cat "${keystorePasswordPath}")"
    fi
    if [[ -r "${keyPasswordPath}" ]]; then
      export WWW_SHIELD_KEY_PASSWORD="$(cat "${keyPasswordPath}")"
    fi
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -r "${keystorePasswordPath}"
      set -gx WWW_SHIELD_KEYSTORE_PASSWORD (cat "${keystorePasswordPath}")
    end
    if test -r "${keyPasswordPath}"
      set -gx WWW_SHIELD_KEY_PASSWORD (cat "${keyPasswordPath}")
    end
  '';

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
