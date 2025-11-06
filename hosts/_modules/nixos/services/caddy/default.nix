# Enhanced Caddy module with structured backend and security configuration
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.modules.services.caddy;

  # Find all vhosts with Authelia enabled to dynamically build systemd dependencies
  autheliaEnabledVhosts = filter (vhost: vhost.enable && vhost.authelia != null && vhost.authelia.enable) (attrValues cfg.virtualHosts);
  autheliaInstances = unique (map (vhost: vhost.authelia.instance or "main") autheliaEnabledVhosts);

  # Helper: Build backend URL from structured config
  buildBackendUrl = vhost:
    if vhost.backend != null then
      "${vhost.backend.scheme}://${vhost.backend.host}:${toString vhost.backend.port}"
    else if vhost.proxyTo != null then
      # Legacy support: add http:// if no scheme present
      if hasPrefix "http" vhost.proxyTo then vhost.proxyTo else "http://${vhost.proxyTo}"
    else
      throw "Virtual host '${vhost.hostName}' must specify either 'backend' or 'proxyTo'";

  # Helper: Generate TLS transport block for HTTPS backends
  generateTlsTransport = vhost:
    if vhost.backend != null && vhost.backend.scheme == "https" then
      let
        tls = vhost.backend.tls;
        verifyDisabled = !tls.verify;
        sniOverride = tls.sni != null;
        customCa = tls.caFile != null;
      in
        if verifyDisabled || sniOverride || customCa then ''
            transport http {
              tls${optionalString sniOverride " ${tls.sni}"}
              ${optionalString verifyDisabled "tls_insecure_skip_verify"}
              ${optionalString customCa "tls_trusted_ca_certs ${tls.caFile}"}
            }''
        else ""
    else "";

  # Helper: Generate security headers from structured config
  generateSecurityHeaders = vhost:
    let
      # Build HSTS header if enabled (default is enabled)
      hstsHeader =
        if vhost.security.hsts.enable then
          let
            maxAge = "max-age=${toString vhost.security.hsts.maxAge}";
            subdomains = optionalString vhost.security.hsts.includeSubDomains "; includeSubDomains";
            preload = optionalString vhost.security.hsts.preload "; preload";
          in {
            "Strict-Transport-Security" = "${maxAge}${subdomains}${preload}";
          }
        else {};

      # Merge HSTS with custom security headers
      allHeaders = hstsHeader // vhost.security.customHeaders;

      # Convert to Caddy header block format
      headerLines = mapAttrsToList (name: value: "    ${name} \"${value}\"") allHeaders;
    in
      if allHeaders != {} then ''
          header {
${concatStringsSep "\n" headerLines}
          }
'' else "";
in
{
  imports = [
    ./dns-records.nix
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
      description = "Base domain for auto-generated virtual hosts (legacy support). The 'hostName' option in each virtual host is now preferred.";
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

    # Virtual hosts configuration with structured backend and security options
    virtualHosts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "this virtual host";

          hostName = mkOption {
            type = types.str;
            description = "The fully qualified domain name for this virtual host";
            example = "example.holthome.net";
          };

          # New structured backend configuration
          backend = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                scheme = mkOption {
                  type = types.enum [ "http" "https" ];
                  default = "http";
                  description = "Backend protocol";
                };
                host = mkOption {
                  type = types.str;
                  default = "127.0.0.1";
                  description = "Backend host address";
                };
                port = mkOption {
                  type = types.port;
                  description = "Backend port";
                };
                tls = mkOption {
                  type = types.submodule {
                    options = {
                      verify = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Verify backend TLS certificate";
                      };
                      sni = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Override TLS Server Name Indication";
                      };
                      caFile = mkOption {
                        type = types.nullOr types.path;
                        default = null;
                        description = "Path to custom CA certificate file";
                      };
                    };
                  };
                  default = {};
                  description = "TLS settings for HTTPS backends";
                };
              };
            });
            default = null;
            description = "Structured backend configuration (preferred)";
          };

          # Legacy support - will be deprecated
          proxyTo = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Legacy: The backend address to proxy to (use 'backend' option instead)";
            example = "localhost:8080";
          };

          httpsBackend = mkOption {
            type = types.bool;
            default = false;
            description = "Legacy: Whether the backend uses HTTPS (use 'backend.scheme' instead)";
          };

          # Authentication configuration
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
            description = "Basic authentication configuration";
          };

          # New structured security configuration
          security = mkOption {
            type = types.submodule {
              options = {
                hsts = mkOption {
                  type = types.submodule {
                    options = {
                      enable = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Enable HSTS";
                      };
                      maxAge = mkOption {
                        type = types.int;
                        default = 15552000;  # 6 months
                        description = "HSTS max-age in seconds";
                      };
                      includeSubDomains = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Include subdomains in HSTS";
                      };
                      preload = mkOption {
                        type = types.bool;
                        default = false;
                        description = "Enable HSTS preload";
                      };
                    };
                  };
                  default = {};
                  description = "HTTP Strict Transport Security settings";
                };
                customHeaders = mkOption {
                  type = types.attrsOf types.str;
                  default = {};
                  description = "Custom security headers at site level";
                  example = {
                    "X-Frame-Options" = "SAMEORIGIN";
                    "X-Content-Type-Options" = "nosniff";
                  };
                };
              };
            };
            default = {};
            description = "Security configuration";
          };

          # Caddy-specific reverse proxy directives
          reverseProxyBlock = mkOption {
            type = types.lines;
            default = "";
            description = "Directives for inside the reverse_proxy block";
            example = ''
              header_up Host {upstream_hostport}
              header_up X-Real-IP {remote_host}
            '';
          };

          # Additional site-level configuration
          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Additional site-level Caddy directives";
          };

          # Authelia forward authentication (passed through from service reverseProxy.authelia)
          authelia = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            internal = true;
            description = "Authelia configuration passed from service module (handled by Caddy module)";
          };
        };
      });
      default = {};
      description = "Caddy virtual host configurations with structured backend and security options";
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

    # Validation for virtual hosts
    assertions =
      # Virtual host validation
      (mapAttrsToList (name: vhost: {
        assertion = !vhost.enable || (vhost.backend != null || vhost.proxyTo != null);
        message = "Virtual host '${name}' must specify either 'backend' or 'proxyTo' when enabled.";
      }) cfg.virtualHosts) ++
      (mapAttrsToList (name: vhost: {
        assertion = !vhost.enable || vhost.auth == null || (vhost.auth.user != "" && vhost.auth.passwordHashEnvVar != "");
        message = "Virtual host '${name}' has incomplete authentication configuration.";
      }) cfg.virtualHosts) ++
      # ACME credentials check
      [{
        assertion = cfg.acme.provider != "http" -> (cfg.acme.credentials.envVar != "");
        message = "Caddy ACME provider '${cfg.acme.provider}' requires credentials.envVar to be set.";
      }];

    # Add systemd dependencies on Authelia if any vhost uses it
    # Dynamically builds dependencies for all Authelia instances in use
    systemd.services.caddy = mkIf (autheliaEnabledVhosts != []) {
      wants = map (instance: "authelia-${instance}.service") autheliaInstances;
      after = map (instance: "authelia-${instance}.service") autheliaInstances;
    };

    # Enable the standard NixOS Caddy service
    services.caddy = {
      enable = true;
      package = cfg.package;

      # Generate configuration from virtual hosts using new structured approach
      extraConfig =
        let
          # Helper: Build Authelia verification URL
          buildAutheliaUrl = authCfg:
            "${authCfg.autheliaScheme}://${authCfg.autheliaHost}:${toString authCfg.autheliaPort}";

          # Helper: Generate forward_auth block for Authelia-protected hosts
          generateAutheliaForwardAuth = authCfg: ''
            # Authelia SSO forward authentication
            # NOTE: ALL traffic goes through forward_auth - Authelia handles bypass logic
            forward_auth ${buildAutheliaUrl authCfg} {
              uri /api/verify?rd=https://${authCfg.authDomain}
              copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
            }'';

          # Generate configuration for each virtual host
          vhostConfigs = filter (s: s != "") (mapAttrsToList (name: vhost:
            let
              hasAuthelia = vhost.authelia != null && vhost.authelia.enable;
              # Disable basic auth if Authelia is enabled
              useBasicAuth = vhost.auth != null && !hasAuthelia;

              # IP-restricted bypass configuration
              hasBypassPaths = hasAuthelia && (vhost.authelia.bypassPaths or []) != [];
              hasNetworkRestrictions = hasAuthelia && (vhost.authelia.allowedNetworks or []) != [];
              useIpRestrictedBypass = hasBypassPaths && hasNetworkRestrictions;
              bypassPathPatterns = map (path: "${path}*") (vhost.authelia.bypassPaths or []);

              backendUrl = buildBackendUrl vhost;
              tlsTransport = generateTlsTransport vhost;

              # Generate IP-restricted routes for bypass paths
              ipRestrictedBypassConfig = optionalString useIpRestrictedBypass ''
                # Matcher: API/bypass paths from internal networks only
                @internalApi {
                  path ${concatStringsSep " " bypassPathPatterns}
                  remote_ip ${concatStringsSep " " vhost.authelia.allowedNetworks}
                }

                # Route: Direct access for trusted internal IPs (skip Authelia)
                route @internalApi {
                  reverse_proxy ${backendUrl} {${tlsTransport}
                    ${vhost.reverseProxyBlock}
                  }
                }

              '';
            in
              if vhost.enable then ''
                ${vhost.hostName} {
                  # ACME TLS configuration
                  ${cfg.acme.generateTlsBlock}

                  # Security headers (includes HSTS by default)
                  ${generateSecurityHeaders vhost}
                  ${optionalString useBasicAuth ''
                  # Basic authentication
                  basic_auth {
                    ${vhost.auth.user} {env.${vhost.auth.passwordHashEnvVar}}
                  }
                  ''}
                  ${ipRestrictedBypassConfig}${optionalString hasAuthelia (generateAutheliaForwardAuth vhost.authelia)}
                  # Reverse proxy to backend
                  reverse_proxy ${backendUrl} {${tlsTransport}
                    ${vhost.reverseProxyBlock}
                  }
                  ${optionalString (vhost.extraConfig != "") "# Additional site-level directives\n                  ${vhost.extraConfig}"}
                }
              '' else ""
          ) cfg.virtualHosts);
        in
          concatStringsSep "\n\n" vhostConfigs;
    };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
