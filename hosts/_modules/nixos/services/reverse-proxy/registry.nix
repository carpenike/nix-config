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
#     backend = { host = "localhost"; port = 8080; };
#     # ... other options
#   };

{ config, lib, ... }:
with lib;
let
  # FQDN validation regex
  fqdnRegex = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$";
in
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
            type = types.strMatching fqdnRegex;
            description = "The fully qualified domain name for this virtual host";
            example = "omada.holthome.net";
          };

          # DEPRECATED: Use backend.* instead
          proxyTo = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              DEPRECATED: Use backend.host and backend.port instead.
              The backend address to proxy to (e.g., "localhost:8043").
              This option is kept for backward compatibility but will be removed in the future.
            '';
          };

          backend = mkOption {
            type = types.submodule {
              options = {
                scheme = mkOption {
                  type = types.enum [ "http" "https" ];
                  default = "http";
                  description = "Backend protocol scheme";
                };

                host = mkOption {
                  type = types.str;
                  default = "localhost";
                  description = "Backend hostname or IP address";
                };

                port = mkOption {
                  type = types.ints.between 1 65535;
                  description = "Backend port number";
                  example = 8080;
                };

                tls = mkOption {
                  type = types.submodule {
                    options = {
                      verify = mkOption {
                        type = types.bool;
                        default = true;
                        description = ''
                          Whether to verify backend TLS certificates.
                          WARNING: Setting this to false disables certificate validation and is insecure.
                          Only use for trusted internal services with self-signed certificates.
                        '';
                      };

                      acknowledgeInsecure = mkOption {
                        type = types.bool;
                        default = false;
                        description = ''
                          Required acknowledgment when verify = false.
                          You must explicitly set this to true when disabling TLS verification.
                        '';
                      };

                      sni = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Server Name Indication (SNI) override for backend TLS";
                      };

                      caFile = mkOption {
                        type = types.nullOr types.path;
                        default = null;
                        description = "Custom CA certificate file for backend verification";
                      };
                    };
                  };
                  default = {};
                  description = "TLS configuration for HTTPS backends";
                };
              };
            };
            default = {};
            description = "Structured backend configuration (replaces proxyTo)";
          };

          # DEPRECATED: Use securityHeaders instead
          headers = mkOption {
            type = types.lines;
            default = "";
            description = ''
              DEPRECATED: Use securityHeaders for structured configuration.
              Header directives to include inside the reverse_proxy block.
              This option is Caddy-specific and will be moved to vendorExtensions.caddy.
            '';
          };

          securityHeaders = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = ''
              Structured security headers to apply to responses.
              Backend-agnostic format that can be translated to any proxy implementation.
            '';
            example = {
              X-Frame-Options = "SAMEORIGIN";
              X-Content-Type-Options = "nosniff";
              X-XSS-Protection = "1; mode=block";
              Referrer-Policy = "strict-origin-when-cross-origin";
            };
          };

          security = mkOption {
            type = types.submodule {
              options = {
                hsts = mkOption {
                  type = types.submodule {
                    options = {
                      enable = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Enable HTTP Strict Transport Security";
                      };

                      maxAge = mkOption {
                        type = types.ints.positive;
                        default = 15552000; # 6 months
                        description = "HSTS max-age in seconds";
                      };

                      includeSubDomains = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Apply HSTS to all subdomains";
                      };

                      preload = mkOption {
                        type = types.bool;
                        default = false;
                        description = "Include preload directive (for HSTS preload list submission)";
                      };
                    };
                  };
                  default = {};
                  description = "HTTP Strict Transport Security configuration";
                };
              };
            };
            default = {};
            description = "Security policy configuration";
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

          # DEPRECATED: Use vendorExtensions.caddy.extraConfig instead
          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = ''
              DEPRECATED: Use vendorExtensions.caddy.extraConfig for Caddy-specific config.
              Extra Caddyfile directives for this virtual host.
              This option will be removed to maintain backend agnosticism.
            '';
          };

          vendorExtensions = mkOption {
            type = types.submodule {
              options = {
                caddy = mkOption {
                  type = types.submodule {
                    options = {
                      extraConfig = mkOption {
                        type = types.lines;
                        default = "";
                        description = "Caddy-specific configuration directives";
                      };

                      reverseProxyBlock = mkOption {
                        type = types.lines;
                        default = "";
                        description = "Caddy-specific directives inside the reverse_proxy block";
                      };
                    };
                  };
                  default = {};
                  description = "Caddy-specific extensions";
                };
              };
            };
            default = {};
            description = "Vendor-specific extensions for proxy implementations";
          };

          publishDns = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to publish DNS records for this virtual host";
          };
        };
      });
      default = {};
      description = "Declarative virtual hosts registered by services or host configs";
    };
  };

  config = {
    # Validation assertions
    assertions = flatten (mapAttrsToList (name: vhost: [
      {
        assertion = !vhost.enable || (builtins.match fqdnRegex vhost.hostName != null);
        message = "Virtual host '${name}' has invalid hostname '${vhost.hostName}'. Must be a valid FQDN.";
      }
      {
        assertion = !vhost.enable || vhost.backend.port >= 1 && vhost.backend.port <= 65535;
        message = "Virtual host '${name}' has invalid port ${toString vhost.backend.port}. Must be between 1 and 65535.";
      }
      {
        assertion = !vhost.enable ||
          (vhost.backend.scheme == "https" && !vhost.backend.tls.verify) -> vhost.backend.tls.acknowledgeInsecure;
        message = ''
          Virtual host '${name}' disables TLS verification without acknowledgment.
          When backend.tls.verify = false, you must set backend.tls.acknowledgeInsecure = true.
          WARNING: Disabling TLS verification is insecure and should only be used for trusted internal services.
        '';
      }
      {
        assertion = !vhost.enable || vhost.auth == null || (vhost.auth.user != "" && vhost.auth.passwordHashEnvVar != "");
        message = "Virtual host '${name}' has incomplete authentication configuration.";
      }
      # Warn about deprecated options
      {
        assertion = !vhost.enable || (vhost.proxyTo == null);
        message = "Virtual host '${name}' uses deprecated 'proxyTo' option. Please migrate to 'backend.host' and 'backend.port'.";
      }
    ]) config.modules.reverseProxy.virtualHosts);

    # Check for duplicate hostNames across all virtual hosts
    warnings =
      let
        enabledVhosts = filterAttrs (_: vhost: vhost.enable) config.modules.reverseProxy.virtualHosts;
        hostnames = mapAttrsToList (_: vhost: vhost.hostName) enabledVhosts;
        duplicates = filter (hostname:
          length (filter (h: h == hostname) hostnames) > 1
        ) (unique hostnames);
      in
        map (hostname:
          "Duplicate hostname '${hostname}' found in reverse proxy virtual hosts. This may cause conflicts."
        ) duplicates;
  };
}
