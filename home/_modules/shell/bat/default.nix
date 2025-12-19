{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.bat;
in
{
  options.modules.shell.bat = {
    enable = lib.mkEnableOption "bat - cat with syntax highlighting";
  };

  config = lib.mkIf cfg.enable {
    programs.bat = {
      enable = true;
      catppuccin.enable = true;
      config = {
        pager = "less -FR";
        style = "numbers,changes,header";
      };
      extraPackages = with pkgs.bat-extras; [
        batdiff
        batgrep
        batman
      ];
    };

    # Add abbreviation to use bat instead of cat
    programs.fish.shellAbbrs = lib.mkIf config.programs.fish.enable {
      cat = "bat";
    };
  };
}
