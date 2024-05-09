{
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.haproxy;
  k8sApiPort = 6443;
  haProxyStatsPort = 8404;
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
    services.haproxy.config = cfg.config;
    networking.firewall.allowedTCPPorts = [ k8sApiPort haProxyStatsPort ];
  };
}