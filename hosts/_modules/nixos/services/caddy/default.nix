# Enhanced Caddy module with seamless service integration
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.modules.services.caddy;
  registryCfg = config.modules.reverseProxy;

  # Helper: Build backend URL from structured config
  buildBackendUrl = vhost:
    let
      # Support legacy proxyTo if set
      legacy = vhost.proxyTo != null;
      scheme = if legacy then "" else "${vhost.backend.scheme}://";
      hostPort = if legacy then vhost.proxyTo else "${vhost.backend.host}:${toString vhost.backend.port}";
    in "${scheme}${hostPort}";

  # Helper: Generate TLS transport block for HTTPS backends
  generateTlsTransport = vhost:
    if vhost.backend.scheme == "https" then
      let
        verifyDisabled = !vhost.backend.tls.verify;
        sniOverride = vhost.backend.tls.sni != null;
        customCa = vhost.backend.tls.caFile != null;
      in ''
            transport http {
              tls${optionalString sniOverride " ${vhost.backend.tls.sni}"}
              ${optionalString verifyDisabled "tls_insecure_skip_verify"}
              ${optionalString customCa "tls_trusted_ca_certs ${vhost.backend.tls.caFile}"}
            }''
    else "";

  # Helper: Generate security headers from structured config
  generateSecurityHeaders = vhost:
    let
      # Build HSTS header if enabled
      hstsHeader =
        if vhost.security.hsts.enable then
          let
            maxAge = "max-age=${toString vhost.security.hsts.maxAge}";
            subdomains = optionalString vhost.security.hsts.includeSubDomains "; includeSubDomains";
            preload = optionalString vhost.security.hsts.preload "; preload";
          in {
            Strict-Transport-Security = "${maxAge}${subdomains}${preload}";
          }
        else {};

      # Merge with custom security headers
      allHeaders = hstsHeader // vhost.securityHeaders;

      # Convert to Caddy header block format
      headerLines = mapAttrsToList (name: value: "    ${name} \"${value}\"") allHeaders;
    in
      if allHeaders != {} then ''
          header {
${concatStringsSep "\n" headerLines}
          }
'' else "";

  # Generate Caddyfile configuration from registered virtual hosts
  generateVhostConfig = vhosts:
    concatStringsSep "\n\n" (mapAttrsToList (name: vhost:
      if vhost.enable then ''
        ${vhost.hostName} {
          # ACME TLS configuration
          ${cfg.acme.generateTlsBlock}

          # Security headers
          ${generateSecurityHeaders vhost}
          ${optionalString (vhost.auth != null) ''
          # Basic authentication
          basic_auth {
            ${vhost.auth.user} {env.${vhost.auth.passwordHashEnvVar}}
          }
          ''}
          # Reverse proxy to backend
          reverse_proxy ${buildBackendUrl vhost} {${generateTlsTransport vhost}
            ${optionalString (vhost.headers != "") "# DEPRECATED: Use securityHeaders instead\n            ${vhost.headers}"}
            ${vhost.vendorExtensions.caddy.reverseProxyBlock}
          }
          ${optionalString (vhost.extraConfig != "") "# DEPRECATED: Use vendorExtensions.caddy.extraConfig instead\n          ${vhost.extraConfig}"}
          ${vhost.vendorExtensions.caddy.extraConfig}
        }
      '' else ""
    ) vhosts);
in
{
  imports = [
    ./dns-records.nix
    # Backward compatibility: redirect old path to new registry
    (lib.mkRenamedOptionModule
      [ "modules" "services" "caddy" "virtualHosts" ]
      [ "modules" "reverseProxy" "virtualHosts" ])
  ];

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
      description = "Base domain for auto-generated virtual hosts (deprecated - use modules.reverseProxy.domain)";
    };

    # ACME/TLS configuration
    acme = mkOption {
      type = types.submodule {
        options = {
          provider = mkOption {
            type = types.enum [ "cloudflare" "http" "zerossl" "letsencrypt" ];
            default = "cloudflare";
            description = "ACME DNS provider for certificate challenges";
          };

          resolvers = mkOption {
            type = types.listOf types.str;
            default = [ "1.1.1.1:53" "8.8.8.8:53" ];
            description = "DNS resolvers for ACME DNS-01 challenge verification";
          };

          credentials = mkOption {
            type = types.submodule {
              options = {
                envVar = mkOption {
                  type = types.str;
                  default = "CLOUDFLARE_API_TOKEN";
                  description = "Environment variable containing DNS provider credentials";
                };
              };
            };
            default = {};
            description = "Credentials configuration for DNS provider";
          };

          generateTlsBlock = mkOption {
            type = types.lines;
            internal = true;
            readOnly = true;
            description = "Generated TLS block for Caddyfile (internal use)";
          };
        };
      };
      default = {};
      description = "ACME certificate configuration";
    };

    # NOTE: virtualHosts option moved to modules.reverseProxy.virtualHosts
    # See: hosts/_modules/nixos/services/reverse-proxy/registry.nix
    # Backward compatibility provided via mkRenamedOptionModule in imports

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
    # Generate ACME TLS block based on configuration
    modules.services.caddy.acme.generateTlsBlock =
      let
        provider = cfg.acme.provider;
        resolversStr = concatStringsSep " " cfg.acme.resolvers;
      in ''
        # Use external DNS resolvers for ACME DNS-01 challenge verification
        tls {
          ${optionalString (provider != "http") "dns ${provider} {env.${cfg.acme.credentials.envVar}}"}
          ${optionalString (provider != "http") "resolvers ${resolversStr}"}
        }'';

    # Validation for registered virtual hosts
    assertions =
      # Legacy reverse proxy validation
      (mapAttrsToList (hostname: proxy: {
        assertion = proxy.auth == null || (proxy.auth.user != "" && proxy.auth.passwordHashEnvVar != "");
        message = "Legacy reverse proxy host '${hostname}' has incomplete authentication configuration.";
      }) cfg.reverseProxy) ++
      # ACME credentials check
      [{
        assertion = cfg.acme.provider != "http" -> (cfg.acme.credentials.envVar != "");
        message = "Caddy ACME provider '${cfg.acme.provider}' requires credentials.envVar to be set.";
      }];

    # Enable the standard NixOS Caddy service
    services.caddy = {
      enable = true;
      package = cfg.package;

      # Generate configuration from registered virtual hosts
      extraConfig =
        (generateVhostConfig config.modules.reverseProxy.virtualHosts) +
        # Legacy support for manual reverse proxy config
        (concatStringsSep "\n\n" (mapAttrsToList (hostname: proxy: ''
          ${hostname} {
            ${cfg.acme.generateTlsBlock}

            # HSTS: Force HTTPS for 6 months across all subdomains (legacy default)
            header {
              Strict-Transport-Security "max-age=15552000; includeSubDomains"
            }

            ${optionalString (proxy.auth != null) ''
            basic_auth {
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
