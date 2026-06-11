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
  # All four vars are set directly in the interactive shell init blocks so they
  # land in the same fish/bash sessions. (home.sessionVariables is unreliable
  # here: fish doesn't source hm-session-vars.sh and bash only sources it for
  # login shells, so the non-secret vars went missing while the password
  # loaders below still ran.)
  #
  # The two passwords are decrypted by sops-nix (using my PGP key, which is a
  # recipient for every *.sops.yaml). Guarded on readability so a missing or
  # locked secret never breaks shell startup.
  # Add the password values with:  sops home/ryan/secrets.sops.yaml

  sops = {
    # rymac has no machine age key in .sops.yaml; decrypt with my PGP key.
    gnupg.home = "${config.home.homeDirectory}/.gnupg";
    defaultSopsFile = ../secrets.sops.yaml;
    secrets = {
      "www-shield/keystore-password" = { };
      "www-shield/key-password" = { };
    };
  };

  programs.bash.initExtra = lib.mkAfter ''
    export WWW_SHIELD_KEYSTORE="/Users/ryan/src/material/www-shield-release.jks"
    export WWW_SHIELD_KEY_ALIAS="www-shield"
    if [[ -r "${keystorePasswordPath}" ]]; then
      export WWW_SHIELD_KEYSTORE_PASSWORD="$(cat "${keystorePasswordPath}")"
    fi
    if [[ -r "${keyPasswordPath}" ]]; then
      export WWW_SHIELD_KEY_PASSWORD="$(cat "${keyPasswordPath}")"
    fi
  '';

  programs.fish.interactiveShellInit = lib.mkAfter ''
    set -gx WWW_SHIELD_KEYSTORE "/Users/ryan/src/material/www-shield-release.jks"
    set -gx WWW_SHIELD_KEY_ALIAS "www-shield"
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
