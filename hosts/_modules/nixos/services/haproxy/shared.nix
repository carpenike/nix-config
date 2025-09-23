{ lib, config, ... }:
let
  cfg = config.modules.services.haproxy.shared;
in
{
  options.modules.services.haproxy.shared = {
    enable = lib.mkEnableOption "the shared HAProxy load balancer configuration";

    # Port configuration
    k8sApiPort = lib.mkOption {
      type = lib.types.port;
      default = 6443;
      description = "Port for the Kubernetes API server frontend.";
      example = 6443;
    };

    statsPort = lib.mkOption {
      type = lib.types.port;
      default = 8404;
      description = "Port for the HAProxy stats page and metrics.";
      example = 8404;
    };

    # Backend server configuration
    controlPlaneBackends = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Server name identifier";
            example = "cp-0";
          };
          host = lib.mkOption {
            type = lib.types.str;
            description = "Server hostname or IP address";
            example = "cp-0.holthome.net";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 6443;
            description = "Server port for Kubernetes API";
          };
        };
      });
      default = [
        { name = "cp-0"; host = "cp-0.holthome.net"; port = 6443; }
        { name = "node-0"; host = "node-0.holthome.net"; port = 6443; }
        { name = "node-1"; host = "node-1.holthome.net"; port = 6443; }
        { name = "node-2"; host = "node-2.holthome.net"; port = 6443; }
        { name = "node-3"; host = "node-3.holthome.net"; port = 6443; }
      ];
      description = "List of Kubernetes control plane and worker nodes for load balancing.";
      example = lib.literalExpression ''
        [
          { name = "cp-0"; host = "cp-0.holthome.net"; port = 6443; }
          { name = "node-0"; host = "node-0.holthome.net"; port = 6443; }
        ]
      '';
    };

    # Timeout configuration
    timeouts = {
      httpRequest = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for HTTP requests";
        example = "15s";
      };

      queue = lib.mkOption {
        type = lib.types.str;
        default = "20s";
        description = "Timeout for requests waiting in queue";
        example = "30s";
      };

      connect = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "Timeout for connection establishment";
        example = "10s";
      };

      client = lib.mkOption {
        type = lib.types.str;
        default = "20s";
        description = "Timeout for client connections";
        example = "30s";
      };

      server = lib.mkOption {
        type = lib.types.str;
        default = "20s";
        description = "Timeout for server connections";
        example = "30s";
      };

      httpKeepAlive = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for HTTP keep-alive connections";
        example = "15s";
      };

      check = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Timeout for health checks";
        example = "5s";
      };
    };

    # Health check configuration
    healthCheck = {
      path = lib.mkOption {
        type = lib.types.str;
        default = "/healthz";
        description = "Health check endpoint path";
        example = "/health";
      };

      expectedStatus = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = "Expected HTTP status code for health checks";
        example = 200;
      };
    };

    # Stats configuration
    stats = {
      uri = lib.mkOption {
        type = lib.types.str;
        default = "/stats";
        description = "URI path for HAProxy statistics page";
        example = "/stats";
      };

      refreshInterval = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Stats page refresh interval";
        example = "30s";
      };
    };

    # DNS dependency option (from original module)
    useDnsDependency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to add a dependency on bind service for hostname resolution";
    };

    # Allow host-specific overrides
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration lines to append to HAProxy config.";
      example = ''
        # Additional custom frontend
        frontend custom_app
            bind *:8080
            default_backend custom_backend
      '';
    };
  };

  # When enabled, apply the shared configuration
  config = lib.mkIf cfg.enable {
    modules.services.haproxy = {
      enable = true;
      inherit (cfg) useDnsDependency;
      config = ''
        #---------------------------------------------------------------------
        # Global settings
        #---------------------------------------------------------------------
        global
            log /dev/log local0
            log /dev/log local1 notice
            daemon

        #---------------------------------------------------------------------
        # Common defaults that all the 'listen' and 'backend' sections will
        # use if not designated in their block
        #---------------------------------------------------------------------
        defaults
            mode                    http
            log                     global
            option                  httplog
            option                  dontlognull
            option http-server-close
            option forwardfor       except 127.0.0.0/8
            option                  redispatch
            retries                 1
            timeout http-request    ${cfg.timeouts.httpRequest}
            timeout queue           ${cfg.timeouts.queue}
            timeout connect         ${cfg.timeouts.connect}
            timeout client          ${cfg.timeouts.client}
            timeout server          ${cfg.timeouts.server}
            timeout http-keep-alive ${cfg.timeouts.httpKeepAlive}
            timeout check           ${cfg.timeouts.check}

        #---------------------------------------------------------------------
        # apiserver frontend which proxys to the control plane nodes
        #---------------------------------------------------------------------
        frontend k8s_apiserver
            bind *:${toString cfg.k8sApiPort}
            mode tcp
            option tcplog
            default_backend k8s_controlplane

        frontend stats
           bind *:${toString cfg.statsPort}
           http-request use-service prometheus-exporter if { path /metrics }
           stats enable
           stats uri ${cfg.stats.uri}
           stats refresh ${cfg.stats.refreshInterval}

        #---------------------------------------------------------------------
        # round robin balancing for apiserver
        #---------------------------------------------------------------------
        backend k8s_controlplane
            option httpchk GET ${cfg.healthCheck.path}
            http-check expect status ${toString cfg.healthCheck.expectedStatus}
            mode tcp
            option ssl-hello-chk
            balance     roundrobin
                ${lib.concatMapStringsSep "\n                "
                  (server: "server ${server.name} ${server.host}:${toString server.port} check")
                  cfg.controlPlaneBackends
                }

        ${cfg.extraConfig}
      '';
    };

    # Configure firewall using the configurable ports (eliminates configuration drift)
    networking.firewall.allowedTCPPorts = [ cfg.k8sApiPort cfg.statsPort ];
  };
}
