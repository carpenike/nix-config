{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.fzf;
in
{
  options.modules.shell.fzf = {
    enable = lib.mkEnableOption "fzf - fuzzy finder";
  };

  config = lib.mkIf cfg.enable {
    programs.fzf = {
      enable = true;
      enableFishIntegration = true;
      enableBashIntegration = true;
      catppuccin.enable = true;

      # Use fd for file finding (faster than find)
      defaultCommand = "fd --type f --hidden --follow --exclude .git";
      fileWidgetCommand = "fd --type f --hidden --follow --exclude .git";
      changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git";

      defaultOptions = [
        "--height 40%"
        "--layout=reverse"
        "--border"
        "--inline-info"
      ];

      # Ctrl+T: files, Ctrl+R: history, Alt+C: cd
      fileWidgetOptions = [
        "--preview 'bat --color=always --style=numbers --line-range=:500 {} 2>/dev/null || cat {}'"
      ];

      historyWidgetOptions = [
        "--sort"
        "--exact"
      ];

      changeDirWidgetOptions = [
        "--preview 'eza --tree --color=always {} | head -200'"
      ];
    };

    # Ensure fd is available for fzf
    home.packages = [ pkgs.fd ];
  };
}
