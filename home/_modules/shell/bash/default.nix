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

      initExtra = lib.mkIf cfg.launchFishForInteractive ''
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
