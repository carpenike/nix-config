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
    services.haproxy = {
      enable = true;
      config = cfg.config;
    };

    networking.firewall.allowedTCPPorts = [ k8sApiPort haProxyStatsPort ];

    # Add systemd service configuration
    systemd.services.haproxy = {
      # Ensure named/bind is running before HAProxy starts
      after = [
        "network.target"
        "network-online.target"
        "named.service"
      ];
      requires = [
        "network.target"
        "named.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };

      # Pre-start script to check DNS resolution
      preStart = ''
        # Check DNS resolution before starting HAProxy
        for host in cp-0.holthome.net node-0.holthome.net node-1.holthome.net node-2.holthome.net node-3.holthome.net; do
          if ! getent hosts "$host" > /dev/null; then
            echo "Cannot resolve $host" >&2
            exit 1
          fi
        done
      '';
    };
  };
}
