{ pkgs
, lib
, config
, ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  inherit (config.home) username homeDirectory;
  cfg = config.modules.shell.fish;
  hasPackage = pname:
    lib.any (p: p ? pname && p.pname == pname) config.home.packages;
  hasAnyNixShell = hasPackage "any-nix-shell";
in
{
  options.modules.shell.fish = {
    enable = lib.mkEnableOption "fish";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      programs.fish = {
        enable = true;
        catppuccin.enable = true;

        plugins = [
          { name = "done"; inherit (pkgs.fishPlugins.done) src; }
          { name = "puffer"; inherit (pkgs.fishPlugins.puffer) src; }
          { name = "autopair"; inherit (pkgs.fishPlugins.autopair) src; }
          { name = "sponge"; inherit (pkgs.fishPlugins.sponge) src; }
        ];

        # Use abbreviations instead of aliases for better UX
        # Abbreviations expand inline, making history cleaner and editable
        shellAbbrs = {
          # Backup management
          backups = "task backup:status";

          # NixOS deployment (short and memorable)
          naf = "task -d ~/src/nix-config nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net";
          nal = "task -d ~/src/nix-config nix:apply-nixos host=luna NIXOS_DOMAIN=holthome.net";
          nbf = "task -d ~/src/nix-config nix:build-forge";
          nbl = "task -d ~/src/nix-config nix:build-luna";

          # Git shortcuts
          g = "git";
          ga = "git add";
          gaa = "git add --all";
          gc = "git commit";
          gcm = "git commit -m";
          gco = "git checkout";
          gd = "git diff";
          gds = "git diff --staged";
          gl = "git log --oneline --graph";
          gp = "git push";
          gpl = "git pull";
          gs = "git status";
          gsw = "git switch";

          # Common commands
          "." = "cd ..";
          ".." = "cd ../..";
          "..." = "cd ../../..";
          md = "mkdir -p";
          rd = "rmdir";

          # Nix shortcuts
          nrs = "sudo nixos-rebuild switch --flake .";
          nrt = "sudo nixos-rebuild test --flake .";
          nfu = "nix flake update";
          nfc = "nix flake check";
          ndev = "nix develop";
        };

        interactiveShellInit = ''
          # Only add paths that exist (avoids cluttering PATH)
          for p in \
            ${homeDirectory}/.local/bin \
            ${homeDirectory}/.cargo/bin \
            ${homeDirectory}/go/bin \
            /run/wrappers/bin \
            /etc/profiles/per-user/${username}/bin \
            /run/current-system/sw/bin \
            /nix/var/nix/profiles/default/bin \
            /opt/homebrew/bin
            test -d $p; and fish_add_path -gm $p
          end

          # GPG/SSH agent setup
          if command -q gpgconf
            set -gx SSH_AUTH_SOCK (gpgconf --list-dirs agent-ssh-socket)
            gpg-connect-agent /bye 2>/dev/null
          end

          # Transient prompt function for starship
          # Shows minimal prompt for previous commands (just the character)
          function starship_transient_prompt_func
            starship module character
          end
        '' + (
          if hasAnyNixShell
          then ''
            any-nix-shell fish --info-right | source
          ''
          else ""
        );
      };

      home.sessionVariables.fish_greeting = "";

      programs.nix-index.enable = true;
    })

    (lib.mkIf (cfg.enable && isDarwin) {
      programs.fish = {
        functions = {
          flushdns = {
            description = "Flush DNS cache";
            body = builtins.readFile ./functions/flushdns.fish;
          };
        };
      };
    })
  ];
}
