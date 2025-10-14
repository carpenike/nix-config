# Reverse Proxy Registry Module
#
# Provides a shared registration interface for services to declare their
# reverse proxy requirements without depending on the Caddy module directly.
#
# This decouples service registration from the proxy implementation, allowing:
# - Host-level service configs to register without module wrappers
# - Service modules to register without circular dependencies
# - Future flexibility to swap proxy backends
#
# Services register by setting:
#   modules.reverseProxy.virtualHosts.<name> = {
#     enable = true;
#     hostName = "service.domain.com";
#     proxyTo = "localhost:8080";
#     # ... other options
#   };

{ config, lib, ... }:
with lib;
{
  options.modules.reverseProxy = {
    domain = mkOption {
      type = types.str;
      default = config.networking.domain or "holthome.net";
      description = "Base domain for auto-generated virtual hosts";
    };

    virtualHosts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "this virtual host";

          hostName = mkOption {
            type = types.str;
            description = "The fully qualified domain name for this virtual host";
            example = "omada.holthome.net";
          };

          proxyTo = mkOption {
            type = types.str;
            description = "The backend address to proxy to";
            example = "localhost:8043";
          };

          httpsBackend = mkOption {
            type = types.bool;
            default = false;
            description = "Whether backend uses HTTPS and requires TLS skip verification";
          };

          headers = mkOption {
            type = types.lines;
            default = "";
            description = "Header directives to include inside the reverse_proxy block";
          };

          auth = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                user = mkOption {
                  type = types.str;
                  description = "Username for basic authentication";
                };
                passwordHashEnvVar = mkOption {
                  type = types.str;
                  description = "Name of environment variable containing bcrypt password hash";
                };
              };
            });
            default = null;
            description = "Optional basic authentication configuration";
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra Caddyfile directives for this virtual host";
          };
        };
      });
      default = {};
      description = "Declarative virtual hosts registered by services or host configs";
    };
  };
}
