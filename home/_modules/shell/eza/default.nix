{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.eza;
in
{
  options.modules.shell.eza = {
    enable = lib.mkEnableOption "eza - modern ls replacement";
  };

  config = lib.mkIf cfg.enable {
    programs.eza = {
      enable = true;
      enableFishIntegration = true;
      enableBashIntegration = true;
      git = true;
      icons = "auto";
      extraOptions = [
        "--group-directories-first"
        "--header"
      ];
    };

    # Add abbreviations for common ls patterns
    programs.fish.shellAbbrs = lib.mkIf config.programs.fish.enable {
      ls = "eza";
      ll = "eza -l";
      la = "eza -la";
      lt = "eza --tree --level=2"; # Tree with 2-level depth limit
      lt3 = "eza --tree --level=3"; # 3 levels if needed
      l = "eza -l";
    };
  };
}
