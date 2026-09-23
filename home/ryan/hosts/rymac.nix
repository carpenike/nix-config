{ pkgs
, config
, lib
, ...
}:
let
  sopsFile = ../secrets.sops.yaml;
  sopsDocument = builtins.readFile sopsFile;
  sshPublicKey = builtins.readFile ../config/ssh/ssh.pub;

  # sops-nix (home-manager) decrypts to a runtime dir and symlinks into the
  # home; reference these paths so the shell loaders never hardcode them.
  keystorePasswordPath = config.sops.secrets."www-shield/keystore-password".path;
  keyPasswordPath = config.sops.secrets."www-shield/key-password".path;
  yubikeyUnlockCommand = "${config.home.profileDirectory}/bin/yubikey-unlock";

  # Exercise each YubiKey-backed key operation so gpg-agent caches its unlock.
  yubikeyUnlock = pkgs.writeShellApplication {
    name = "yubikey-unlock";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnupg
      pkgs.openssh
      pkgs.sops
    ];
    text = ''
      signing_key=${lib.escapeShellArg config.modules.shell.git.signingKey}
      ssh_public_key=${lib.escapeShellArg sshPublicKey}
      sops_document=${lib.escapeShellArg sopsDocument}

      usage() {
        echo "Usage: yubikey-unlock [--recover]"
        echo "  --recover  If card discovery fails, restart your macOS PC/SC helpers."
        echo "             This disconnects other smartcard applications running as your user."
      }

      recover=false
      if (( $# > 1 )); then
        usage >&2
        exit 2
      fi
      if (( $# == 1 )); then
        case "$1" in
          --recover) recover=true ;;
          --help|-h) usage; exit 0 ;;
          *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
      fi

      umask 077
      challenge="$(mktemp "''${TMPDIR:-/tmp}/yubikey-unlock.XXXXXX")"
      gpg_signature="$challenge.gpg"
      ssh_public_key_file="$challenge.pub"
      sops_file="$challenge.sops.yaml"
      card_status_error="$challenge.card-status-error"

      cleanup() {
        rm -f \
          "$challenge" \
          "$gpg_signature" \
          "$ssh_public_key_file" \
          "$sops_file" \
          "$card_status_error"
      }
      trap cleanup EXIT

      check_card() {
        local attempt
        for attempt in 1 2 3; do
          if LC_ALL=C gpg --card-status >/dev/null 2>"$card_status_error"; then
            return 0
          fi

          case "$(<"$card_status_error")" in
            *"OpenPGP card not available: General error"*|\
            *"OpenPGP card not available: Operation not supported by device"*) ;;
            *) return 1 ;;
          esac

          if (( attempt < 3 )); then
            printf 'waiting... '
            sleep 1 || return 1
          fi
        done
        return 1
      }

      card_reader_busy() {
        [[ "$(<"$card_status_error")" == *"OpenPGP card not available: Operation not supported by device"* ]]
      }

      printf 'Checking GnuPG agent... '
      gpgconf --launch gpg-agent
      echo "ready"

      printf 'Checking YubiKey... '
      card_ready=false
      if check_card; then
        card_ready=true
      elif card_reader_busy; then
        printf 'restarting smartcard daemon... '
        gpgconf --kill scdaemon
        if check_card; then
          card_ready=true
        fi
      fi

      if [[ "$card_ready" != true && "$recover" == true ]] && card_reader_busy; then
        current_uid="$(id -u)"
        if [[ "$current_uid" == 0 ]]; then
          echo "Refusing PC/SC recovery as root. Run yku --recover without sudo." >&2
          exit 1
        fi

        printf '\nRestarting your PC/SC helpers; other smartcard sessions will disconnect.\n'
        gpgconf --kill scdaemon
        pcsc_helper="/System/Library/Frameworks/PCSC.framework/Versions/A/XPCServices/com.apple.ctkpcscd.xpc/Contents/MacOS/com.apple.ctkpcscd"
        processes="$(ps -axww -o uid=,pid=,comm=)"
        stopped_helper=false
        while read -r owner pid executable; do
          if [[ "$owner" != "$current_uid" || "$executable" != "$pcsc_helper" || ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
            continue
          fi

          # Recheck identity in case the process exited or its PID was reused.
          if ! identity="$(ps -ww -p "$pid" -o uid=,comm=)" || [[ -z "$identity" ]]; then
            printf 'Cannot verify PC/SC helper PID %s; skipping it.\n' "$pid" >&2
            continue
          fi
          read -r verified_owner verified_executable <<< "$identity"
          if [[ "$verified_owner" != "$current_uid" || "$verified_executable" != "$pcsc_helper" ]]; then
            printf 'Identity changed for PID %s; skipping it.\n' "$pid" >&2
            continue
          fi

          printf 'Stopping your PC/SC helper PID %s...\n' "$pid"
          if ! kill -TERM "$pid"; then
            printf 'Could not stop PC/SC helper PID %s; recovery aborted.\n' "$pid" >&2
            exit 1
          fi
          stopped_helper=true
        done <<< "$processes"

        if [[ "$stopped_helper" != true ]]; then
          echo "No matching user-owned PC/SC helpers were restarted." >&2
        fi
        sleep 1
        printf 'Checking YubiKey again... '
        if check_card; then
          card_ready=true
        fi
      fi

      if [[ "$card_ready" != true ]]; then
        cat "$card_status_error" >&2
        if card_reader_busy; then
          if [[ "$recover" == true ]]; then
            echo "Recovery did not restore card access. Close other smartcard apps and unplug/reinsert the YubiKey." >&2
          else
            echo "macOS card access may be busy or stale. Close other smartcard apps, then run 'yku --recover' to restart your PC/SC helpers." >&2
          fi
        fi
        exit 1
      fi
      echo "ready"

      printf 'Unlocking GPG signing key... '
      printf 'yubikey-unlock\n' > "$challenge"
      gpg \
        --quiet \
        --local-user "$signing_key" \
        --detach-sign \
        --output "$gpg_signature" \
        "$challenge"
      echo "ready"

      printf 'Unlocking SSH authentication key... '
      export SSH_AUTH_SOCK
      SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
      printf '%s' "$ssh_public_key" > "$ssh_public_key_file"
      ssh-add -T "$ssh_public_key_file"
      echo "ready"

      printf 'Unlocking SOPS decryption key... '
      printf '%s' "$sops_document" > "$sops_file"
      sops --decrypt "$sops_file" >/dev/null
      echo "ready"

      echo "YubiKey unlocked for GPG signing, SSH authentication, and SOPS decryption."
    '';
  };
in
{
  home.packages = [
    pkgs.podman
    pkgs.podman-compose
    yubikeyUnlock
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
    defaultSopsFile = sopsFile;
    secrets = {
      "www-shield/keystore-password" = { };
      "www-shield/key-password" = { };
    };
  };

  programs.bash.shellAliases.yku = yubikeyUnlockCommand;

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

  programs.fish.shellAbbrs.yku = yubikeyUnlockCommand;

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
