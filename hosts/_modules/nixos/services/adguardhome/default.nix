{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.adguardhome;
in
{
  options.modules.services.adguardhome = {
    enable = lib.mkEnableOption "adguardhome";
    package = lib.mkPackageOption pkgs "adguardhome" { };
    settings = lib.mkOption {
      default = config.services.adguardhome.settings;
      type = lib.type.str;
    };
  };

  config = lib.mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      mutableSettings = true;
      inherit (cfg) settings;
    };
  };
}