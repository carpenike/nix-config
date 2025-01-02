{
  lib,
  config,
  pkgs,
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

    useDnsDependency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to add a dependency on bind service";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure necessary packages are available
    environment.systemPackages = with pkgs; [
      netcat
      dnsutils  # for dig
    ];

    services.haproxy = {
      enable = true;
      config = cfg.config;
    };

    networking.firewall.allowedTCPPorts = [ k8sApiPort haProxyStatsPort ];

    # Conditionally add systemd service configuration
    systemd.services.haproxy = lib.mkMerge [
      {
        # Ensure the service starts
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Restart = lib.mkOverride 500 "on-failure";
          RestartSec = "5s";

          Type = lib.mkOverride 500 "forking";  # Use mkOverride to resolve conflict
          PIDFile = "/run/haproxy.pid";
        };

        # Comprehensive pre-start script with extensive logging
        preStart = ''
          #!/bin/bash
          set -x  # Enable debug output

          echo "Starting HAProxy pre-start checks" >&2

          # Check network connectivity
          echo "Checking network connectivity..." >&2

          # Try multiple methods to check connectivity
          if nc -z -w5 1.1.1.1 443 2>/dev/null; then
            echo "Network connectivity check passed using netcat" >&2
          elif timeout 5 sh -c "true >/dev/tcp/1.1.1.1/443" 2>/dev/null; then
            echo "Network connectivity check passed using bash" >&2
          else
            echo "Network connectivity check failed" >&2
            exit 1
          fi

          # Check DNS resolution
          echo "Checking DNS resolution..." >&2
          hosts=(
            "cp-0.holthome.net"
            "node-0.holthome.net"
            "node-1.holthome.net"
            "node-2.holthome.net"
            "node-3.holthome.net"
          )

          for host in "''${hosts[@]}"; do
            echo "Resolving $host..." >&2
            if ! getent hosts "$host" > /dev/null 2>&1; then
              echo "Cannot resolve $host" >&2
              exit 1
            fi

            # Additional verbose DNS check
            dig +short "$host" >&2
          done

          echo "All pre-start checks passed" >&2
          exit 0
        '';
      }

      # Only add these dependencies if useDnsDependency is true
      (lib.mkIf cfg.useDnsDependency {
        after = [
          "network.target"
          "network-online.target"
          "bind.service"
        ];
        requires = [
          "network.target"
          "bind.service"
        ];
        wants = [ "network-online.target" ];
      })
    ];
  };
}
