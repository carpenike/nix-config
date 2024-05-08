{
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.haproxy;
in
{
  options.modules.services.haproxy = {
    enable = lib.mkEnableOption "haproxy";
    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };
  };

  config = lib.mkIf cfg.enable {
    services.haproxy.enable = true;
    services.haproxy.package = cfg.package;
    services.haproxy.extraConfig = cfg.config;
  };
}