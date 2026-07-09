{ lib
, config
, ...
}:
let
  cfg = config.modules.shell.bash;
in
{
  options.modules.shell.bash = {
    enable = lib.mkEnableOption "bash shell configuration";

    launchFishForInteractive = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Launch fish shell for interactive sessions while keeping bash
        as the login shell. This is needed for VS Code Remote SSH
        compatibility since it sends POSIX shell commands that fish
        cannot parse.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.bash = {
      enable = true;

      # Task shortcuts for deploying NixOS hosts from any directory.
      # Mirror the fish abbreviations (naf/nap) so bash sessions — e.g. the
      # VS Code Copilot terminal on rymac — get the same one-liner UX.
      # `task -d` makes them work from anywhere. forge builds on itself
      # (apply-nixos); nixpi is a Raspberry Pi on holtel.io, so we build here
      # and push the closure (deploy-nixos) rather than compiling on the Pi.
      shellAliases = {
        naf = "task -d ~/src/nix-config nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net";
        nap = "task -d ~/src/nix-config nix:deploy-nixos host=nixpi NIXOS_DOMAIN=holtel.io";
      };

      # Simple, VS Code Copilot-friendly prompt
      # No fancy escape sequences that confuse terminal parsers
      initExtra = ''
        # Simple prompt for VS Code compatibility
        # Shows user@host:directory$ without complex escape sequences
        PS1='\u@\h:\w\$ '

        # Load Home Assistant bearer token for development/scripting
        # Token is managed via SOPS and readable only by the user
        if [[ -r "/run/secrets/home-assistant/bearer-token" ]]; then
          export HA_BEARER_TOKEN="$(cat /run/secrets/home-assistant/bearer-token)"
        fi

        # Load GitHub personal access token for the gh CLI.
        # gh reads $GH_TOKEN natively and prefers it over its own config file,
        # so this avoids the read-only home-manager hosts.yml problem entirely.
        # Token is managed via SOPS and only readable by the owning user.
        if [[ -r "/run/secrets/users/ryan/github-token" ]]; then
          export GH_TOKEN="$(cat /run/secrets/users/ryan/github-token)"
        fi

        # Load the WWW prod PAT from macOS Keychain into the current shell.
        # Mirrors the fish function of the same name so bash sessions (e.g. the
        # VS Code Copilot terminal on rymac) get the same one-liner UX.
        # One-time setup on macOS:
        #   security add-generic-password -a "$USER" -s www-prod-pat -w
        # Revoke at https://whiskeywhiskeywhiskey.org/#/me/tokens when done.
        www-prod-pat() {
          if ! command -v security >/dev/null 2>&1; then
            echo "www-prod-pat: requires macOS Keychain (security command not found)" >&2
            return 1
          fi
          local pat
          if ! pat="$(security find-generic-password -a "$USER" -s www-prod-pat -w 2>/dev/null)"; then
            echo "No PAT stored. Run: security add-generic-password -a \$USER -s www-prod-pat -w" >&2
            return 1
          fi
          export WWW_PROD_PAT="$pat"
          echo "WWW_PROD_PAT loaded — revoke at https://whiskeywhiskeywhiskey.org/#/me/tokens when done."
        }
      '' + lib.optionalString cfg.launchFishForInteractive ''
        # Launch fish for interactive sessions, but not for VS Code terminals
        # or other non-interactive contexts that need POSIX shell compatibility
        # - VSCODE_RESOLVING_ENVIRONMENT: set during VS Code Remote SSH init
        # - TERM_PROGRAM=vscode: set in VS Code integrated terminals
        # - INSIDE_EMACS: set in Emacs shell buffers
        if [[ $- == *i* ]] && \
           [[ -z "''${VSCODE_RESOLVING_ENVIRONMENT:-}" ]] && \
           [[ "''${TERM_PROGRAM:-}" != "vscode" ]] && \
           [[ -z "''${INSIDE_EMACS:-}" ]]; then
            exec fish
        fi
      '';
    };
  };
}
