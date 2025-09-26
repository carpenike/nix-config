# Enhanced Caddy module with seamless service integration
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.modules.services.caddy;

  # Generate Caddyfile configuration from registered virtual hosts
  generateVhostConfig = vhosts:
    concatStringsSep "\n\n" (mapAttrsToList (name: vhost:
      if vhost.enable then ''
        ${vhost.hostName} {
          ${optionalString (vhost.auth != null) ''
          basicauth {
            ${vhost.auth.user} {env.${vhost.auth.passwordHashEnvVar}}
          }
          ''}
          reverse_proxy ${vhost.proxyTo} {
${optionalString vhost.httpsBackend ''            transport http {
              tls_insecure_skip_verify
            }
''}${optionalString (vhost.headers != "") ''            ${vhost.headers}
''}          }
          ${vhost.extraConfig}
        }
      '' else ""
    ) vhosts);
in
{
  options.modules.services.caddy = {
    enable = mkEnableOption "Caddy web server";

    package = mkOption {
      type = types.package;
      default = pkgs.caddy;
      description = "Caddy package to use";
    };

    domain = mkOption {
      type = types.str;
      default = config.networking.domain or "holthome.net";
      description = "Base domain for auto-generated virtual hosts";
    };

    # Service registration interface - other modules register their services here
    virtualHosts = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
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
      }));
      default = {};
      description = "Declarative virtual hosts registered by services";
    };

    # Legacy support for manual reverse proxy configuration
    reverseProxy = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          target = mkOption {
            type = types.strMatching "^https?://[^/]+.*";
            description = "Target URL to proxy to";
            example = "http://127.0.0.1:3000";
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
        };
      });
      default = {};
      description = "Manual reverse proxy virtual hosts (legacy)";
    };
  };

  config = mkIf cfg.enable {
    # Validation for registered virtual hosts
    assertions =
      # Legacy reverse proxy validation
      (mapAttrsToList (hostname: proxy: {
        assertion = proxy.auth == null || (proxy.auth.user != "" && proxy.auth.passwordHashEnvVar != "");
        message = "Legacy reverse proxy host '${hostname}' has incomplete authentication configuration.";
      }) cfg.reverseProxy) ++
      # Virtual hosts validation
      (mapAttrsToList (hostname: vhost: {
        assertion = !vhost.enable || (vhost.auth == null || (vhost.auth.user != "" && vhost.auth.passwordHashEnvVar != ""));
        message = "Virtual host '${hostname}' has incomplete authentication configuration.";
      }) cfg.virtualHosts);

    # Enable the standard NixOS Caddy service
    services.caddy = {
      enable = true;
      package = cfg.package;

      # Use Cloudflare DNS challenge for Let's Encrypt certificates
      globalConfig = ''
        {
          log {
            level ERROR
          }
          # Use Cloudflare DNS challenge for internal domains
          acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
      '';

      # Generate configuration from registered virtual hosts
      extraConfig =
        (generateVhostConfig cfg.virtualHosts) +
        # Legacy support for manual reverse proxy config
        (concatStringsSep "\n\n" (mapAttrsToList (hostname: proxy: ''
          ${hostname} {
            ${optionalString (proxy.auth != null) ''
            basicauth {
              ${proxy.auth.user} {env.${proxy.auth.passwordHashEnvVar}}
            }
            ''}
            reverse_proxy ${proxy.target}
          }
        '') cfg.reverseProxy));
    };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
