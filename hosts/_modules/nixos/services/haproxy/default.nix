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

    # Add a new option to specify DNS dependency
    useDnsDependency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to add a dependency on named/bind service";
    };
  };

  config = lib.mkIf cfg.enable {
    services.haproxy = {
      enable = true;
      config = cfg.config;
    };

    networking.firewall.allowedTCPPorts = [ k8sApiPort haProxyStatsPort ];

    # Conditionally add systemd service configuration
    systemd.services.haproxy = lib.mkMerge [
      {
        serviceConfig = {
          Restart = lib.mkOverride 500 "on-failure";
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
      }

      # Only add these dependencies if useDnsDependency is true
      (lib.mkIf cfg.useDnsDependency {
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
      })
    ];
  };
}
