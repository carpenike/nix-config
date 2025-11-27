{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.editor.vscode;
in
{
  options.modules.editor.vscode = {
    enable = lib.mkEnableOption "vscode";
    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
    userSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      programs.vscode = {
        enable = true;
        package = pkgs.unstable.vscode;
        mutableExtensionsDir = true;

        profiles.default.extensions = cfg.extensions;
        profiles.default.userSettings = cfg.userSettings;
      };

      # The profiles.default.userSettings already manages settings.json
      # No need for explicit home.file configuration
    })
  ];
}
