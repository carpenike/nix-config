{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.atuin;
in
{
  options.modules.shell.atuin = {
    enable = lib.mkEnableOption "atuin - magical shell history";
  };

  config = lib.mkIf cfg.enable {
    programs.atuin = {
      enable = true;
      enableFishIntegration = true;
      enableBashIntegration = true;
      flags = [
        "--disable-up-arrow" # Don't override up arrow, use Ctrl+R
      ];
      settings = {
        # Use local storage only (no sync)
        auto_sync = false;
        sync_address = "";

        # Search settings
        search_mode = "fuzzy";
        filter_mode = "global";
        filter_mode_shell_up_key_binding = "directory"; # Up arrow searches current dir

        # UI settings
        style = "compact";
        inline_height = 20;
        show_preview = true;
        show_help = true;

        # History settings
        history_filter = [
          "^ls"
          "^cd"
          "^cat"
          "^pwd"
          "^clear"
        ];

        # Don't record secrets
        secrets_filter = true;
      };
    };
  };
}
