{
  pkgs,
  lib,
  config,
  podmanLib,
  ...
}:
let
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

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for 1Password Connect";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "vault";
        description = "Subdomain to use for the reverse proxy";
      };
      requireAuth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to require authentication (highly recommended for vault access)";
      };
      auth = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              default = "vault";
              description = "Username for basic authentication";
            };
            passwordHashEnvVar = lib.mkOption {
              type = lib.types.str;
              description = "Name of environment variable containing bcrypt password hash";
            };
          };
        });
        default = null;
        description = "Authentication configuration for vault endpoint";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.modules.services.caddy.domain or config.networking.domain or "holthome.net"}";
      proxyTo = "localhost:${toString apiPort}";
      httpsBackend = false; # 1Password Connect uses HTTP locally
      auth = lib.mkIf (cfg.reverseProxy.requireAuth && cfg.reverseProxy.auth != null) cfg.reverseProxy.auth;
      extraConfig = ''
        # High security headers for vault access
        header / {
          X-Frame-Options "DENY"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
          Strict-Transport-Security "max-age=31536000; includeSubDomains"
        }
        # API endpoint specific handling
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
        image = "docker.io/1password/connect-api:1.7.2";
        autoStart = true;
        ports = [ "8000:8080" ];
        volumes = [
          "${cfg.credentialsFile}:/home/opuser/.op/1password-credentials.json"
          "${cfg.dataDir}:/home/opuser/.op/data"
        ];
        resources = cfg.resources;
      };

      onepassword-connect-sync = podmanLib.mkContainer "onepassword-connect-sync" {
        image = "docker.io/1password/connect-sync:1.7.2";
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
