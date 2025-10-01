{
  pkgs,
  lib,
  config,
  podmanLib,
  ...
}:
let
  cfg = config.modules.services.omada;
  omadaTcpPorts = [ 8043 8843 29814 ];
  omadaUdpPorts = [ 29810  ];
in
{
  options.modules.services.omada = {
    enable = lib.mkEnableOption "omada";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/data";
    };
    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/log";
    };
    blockOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the system activation should wait for Omada to fully start.
        Set to false to prevent deployment failures when Omada takes time to initialize.
      '';
    };
    restartDelay = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        How long to wait before restarting the service after a failure.
        Increase this on resource-constrained systems.
      '';
    };

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for Omada";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "omada";
        description = "Subdomain to use for the reverse proxy";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8043;
        description = "Omada Controller HTTPS port for reverse proxy";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.modules.services.caddy.domain or config.networking.domain or "holthome.net"}";
      proxyTo = "https://localhost:${toString cfg.reverseProxy.port}";
      httpsBackend = true; # Omada uses HTTPS
      headers = ''
        # Handle websockets for real-time updates
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # Fix redirects by rewriting Location headers from backend
        header_down Location "https://{http.request.host}:8043" "https://{http.request.host}"
      '';
    };

    system.activationScripts = {
      makeOmadaDataDir = lib.stringAfter [ "var" ] ''
        mkdir -p "${cfg.dataDir}"
        chown -R 999:999 ${cfg.dataDir}
      '';
    } // podmanLib.mkLogDirActivation {
      name = "Omada";
      path = cfg.logDir;
      user = "999";
      group = "999";
    };

    # Configure logrotate for Omada application logs
    services.logrotate.settings = podmanLib.mkLogRotate {
      containerName = "omada";
      logDir = cfg.logDir;
      user = "999";
      group = "999";
    };

    # Omada Controller with embedded MongoDB
    virtualisation.oci-containers.containers.omada = podmanLib.mkContainer "omada" {
      image = "docker.io/mbentley/omada-controller:5.14";
      environment = {
        "TZ" = "America/New_York";
        # Using embedded MongoDB (default behavior when MONGO_EXTERNAL is not set)
      };
      autoStart = true;
      ports = [ "8043:8043" "8843:8843" "29814:29814" "29810:29810/udp"  ];
      volumes = [
        "${cfg.dataDir}:/opt/tplink/EAPController/data"
        "${cfg.logDir}:/opt/tplink/EAPController/logs"
      ];
    };

    # Override systemd service to handle Omada's initialization behavior
    systemd.services."${config.virtualisation.oci-containers.backend}-omada" = {
      after = lib.mkForce [ "network-online.target" ];
      wants = lib.mkForce [ "network-online.target" ];

      # Allow more restart attempts during activation
      unitConfig = {
        StartLimitIntervalSec = "10m";
        StartLimitBurst = 5;
      };

      # Increase timeouts for slow initialization
      serviceConfig = {
        # Give Omada more time to start (default is 0 = infinity)
        TimeoutStartSec = lib.mkForce "5m";

        # Give Omada more time to gracefully shut down (default is 120s)
        TimeoutStopSec = lib.mkForce "3m";

        # If it fails, wait before restarting to avoid rapid restart loops
        RestartSec = cfg.restartDelay;

        # Override the default "always" restart behavior to prevent rapid restart loops
        Restart = lib.mkForce "on-failure";
      };

      # Add a post-start script to verify Omada is responding
      postStart = ''
        echo "Waiting for Omada Controller to be ready..."
        for i in {1..60}; do
          if ${pkgs.curl}/bin/curl -k -s -f --max-time 10 https://localhost:8043 >/dev/null 2>&1; then
            echo "Omada Controller is ready!"
            break
          fi
          echo "Waiting for Omada Controller... ($i/60)"
          sleep 5
        done
      '';
    };

    # If not blocking on activation, start Omada after the main system is up
    # This prevents deployment failures due to Omada's slow initialization
    systemd.targets.omada-ready = lib.mkIf (!cfg.blockOnActivation) {
      description = "Omada Controller Ready";
      after = [ "${config.virtualisation.oci-containers.backend}-omada.service" ];
      wants = [ "${config.virtualisation.oci-containers.backend}-omada.service" ];
    };

    networking.firewall.allowedTCPPorts = omadaTcpPorts;
    networking.firewall.allowedUDPPorts = omadaUdpPorts;
  };
}
