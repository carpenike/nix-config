{ config
, lib
, ...
}:
let
  cfg = config.modules.security.ssh;
in
{
  options.modules.security.ssh = {
    enable = lib.mkEnableOption "ssh";
    matchBlocks = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.ssh = {
      enable = true;

      # Disable default config injection, set our own defaults via wildcard match
      enableDefaultConfig = false;

      # Merge user-provided matchBlocks with our defaults
      matchBlocks = cfg.matchBlocks // {
        # Wildcard block for global defaults (replaces deprecated controlMaster/controlPath)
        "*" = {
          controlMaster = "auto";
          controlPath = "~/.ssh/control/%C";
        };
      };

      includes = [
        "config.d/*"
      ];
    };
  };
}
