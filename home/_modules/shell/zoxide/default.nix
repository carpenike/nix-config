{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.zoxide;
in
{
  options.modules.shell.zoxide = {
    enable = lib.mkEnableOption "zoxide - smarter cd command";
  };

  config = lib.mkIf cfg.enable {
    programs.zoxide = {
      enable = true;
      enableFishIntegration = true;
      enableBashIntegration = true;
      options = [
        "--cmd cd" # Replace cd with zoxide
      ];
    };
  };
}
