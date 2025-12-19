{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.modules.shell.direnv;
in
{
  options.modules.shell.direnv = {
    enable = lib.mkEnableOption "direnv - per-directory environment";
  };

  config = lib.mkIf cfg.enable {
    programs.direnv = {
      enable = true;
      enableBashIntegration = true;
      nix-direnv.enable = true; # Faster nix integration with caching

      config = {
        global = {
          load_dotenv = true;
          strict_env = true;
        };
        whitelist = {
          prefix = [
            "~/src"
            "~/projects"
          ];
        };
      };
    };

    # Fish integration is automatic when fish is enabled
  };
}
