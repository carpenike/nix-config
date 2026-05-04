{ lib
, config
, mylib
, podmanLib
, ...
}:
let
  sharedTypes = mylib.types;
  cfg = config.modules.services.onepassword-connect;
  apiPort = 8000;
in
{
  options.modules.services.onepassword-connect = {
    enable = lib.mkEnableOption "onepassword-connect";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/onepassword-connect/data";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "999";
      description = "User ID to own the data directory";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "999";
      description = "Group ID to own the data directory";
    };
    resources = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "128m";
            description = "Memory limit for each container (e.g., '128m', '256m')";
          };
          memoryReservation = lib.mkOption {
            type = lib.types.str;
            default = "64m";
            description = "Memory reservation (soft limit) for each container";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "0.25";
            description = "CPU limit in cores (e.g., '0.25', '0.5')";
          };
        };
      });
      default = {
        memory = "128M";
        memoryReservation = "64M";
        cpus = "0.25";
      };
      description = "Resource limits for the 1Password Connect containers (lightweight API services)";
    };

    # Standard reverse proxy integration via the shared submodule.
    # Caddy registration is wired up below when reverseProxy != null && .enable.
    # Note: 1Password Connect uses native token-based auth (OP_CONNECT_TOKEN),
    # so external Caddy auth is typically left null.
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for the 1Password Connect API.";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts."${cfg.reverseProxy.hostName}" =
      lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = lib.mkDefault {
          scheme = "http"; # 1Password Connect serves HTTP locally
          host = "localhost";
          port = apiPort;
        };

        # Token-based auth is enforced by Connect itself; only attach Caddy
        # auth when the consumer explicitly opts in.
        auth = cfg.reverseProxy.auth;

        # HSTS is on by default in the shared submodule. Layer extra
        # browser-hardening headers on top of any consumer-provided ones.
        security = cfg.reverseProxy.security // {
          customHeaders = {
            "X-Frame-Options" = "DENY";
            "X-Content-Type-Options" = "nosniff";
            "X-XSS-Protection" = "1; mode=block";
            "Referrer-Policy" = "strict-origin-when-cross-origin";
          } // (cfg.reverseProxy.security.customHeaders or { });
        };

        # Force JSON content-type on the v1 API surface (defensive, in case
        # an upstream response omits the header).
        extraConfig = ''
          header /v1/* {
            Content-Type "application/json"
          }
        '';
      };

    system.activationScripts.makeOnePasswordConnectDataDir = lib.stringAfter [ "var" ] ''
      mkdir -p "${cfg.dataDir}"
      chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
    '';

    virtualisation.oci-containers.containers = {
      onepassword-connect-api = podmanLib.mkContainer "onepassword-connect-api" {
        image = "docker.io/1password/connect-api:1.8.2@sha256:e915c0c843972f02b0e7e2de502bda8bd4a092288b3f1866098a857bd715a281";
        autoStart = true;
        ports = [ "8000:8080" ];
        volumes = [
          "${cfg.credentialsFile}:/home/opuser/.op/1password-credentials.json"
          "${cfg.dataDir}:/home/opuser/.op/data"
        ];
        resources = cfg.resources;
      };

      onepassword-connect-sync = podmanLib.mkContainer "onepassword-connect-sync" {
        image = "docker.io/1password/connect-sync:1.8.2@sha256:6297ca6136c0f0fb096bc64c49e1bc8df2aab35282ebff8c7bb60745ef176d0d";
        autoStart = true;
        volumes = [
          "${cfg.credentialsFile}:/home/opuser/.op/1password-credentials.json"
          "${cfg.dataDir}:/home/opuser/.op/data"
        ];
        resources = cfg.resources;
      };
    };
    networking.firewall.allowedTCPPorts = [ apiPort ];
  };
}
