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
          in
          {
            "Strict-Transport-Security" = "${maxAge}${subdomains}${preload}";
          }
        else { };

      # Merge HSTS with custom security headers
      allHeaders = hstsHeader // vhost.security.customHeaders;

      # Convert to Caddy header block format
      headerLines = mapAttrsToList (name: value: "    ${name} \"${value}\"") allHeaders;
    in
    if allHeaders != { } then ''
                header {
      ${concatStringsSep "\n" headerLines}
                }
    '' else "";

  sanitizeForMatcher = name:
    replaceStrings [ "." ":" "/" "*" "@" "-" ] [ "_" "_" "_" "_" "_" "_" ] name;

  indentLines = text:
    let
      lines = lib.splitString "\n" text;
    in
    concatStringsSep "\n" (map (line: "  " + line) lines);

  getPortalConfig = portalName:
    attrByPath [ portalName ] null cfg.security.authenticationPortals;

  getIdentityProviderConfig = providerName:
    attrByPath [ providerName ] null cfg.security.identityProviders;

  portalRealm = portalName:
    let
      portalCfg = getPortalConfig portalName;
      firstProvider =
        if portalCfg != null && portalCfg.identityProviders != [ ] then
          builtins.head portalCfg.identityProviders
        else
          null;
      providerCfg = if firstProvider != null then getIdentityProviderConfig firstProvider else null;
      providerRealm =
        if providerCfg != null && providerCfg ? realm then providerCfg.realm else null;
    in
    if providerRealm != null then providerRealm else portalName;

  formatClaimRoleTransform = { realm, claim, value, role }: ''
    transform user {
      match realm ${realm}
      match ${claim} ${value}
      action add role ${role}
    }
  '';

  portalClaimRoleTransforms =
    let
      accumulate = acc: vhost:
        let
          secCfg = vhost.caddySecurity;
        in
        if vhost.enable && secCfg != null && secCfg.enable && secCfg.claimRoles != [ ] then
          let
            portalName = secCfg.portal;
            defaultRealm = portalRealm portalName;
            transforms = map
              (claimRole:
                let
                  realm = if claimRole.realm != null then claimRole.realm else defaultRealm;
                  claim = claimRole.claim;
                  value = claimRole.value;
                  role = claimRole.role;
                in
                formatClaimRoleTransform { inherit realm claim value role; }
              )
              secCfg.claimRoles;
            existing = attrByPath [ portalName ] [ ] acc;
          in
          acc // { "${portalName}" = existing ++ transforms; }
        else
          acc;
    in
    mapAttrs (_: transforms: concatStrings (unique transforms)) (foldl' accumulate { } (attrValues cfg.virtualHosts));

  securityBlock =
    let
      sec = cfg.security;

      providerBlocks = mapAttrsToList
        (name: provider:
          let
            secretPlaceholder = "{$" + provider.clientSecretEnvVar + "}";
            scopesLine = concatStringsSep " " provider.scopes;
            extra = provider.extraConfig;
          in
          ''
              oauth identity provider ${name} {
              realm ${provider.realm}
              driver ${provider.driver}
              client_id ${provider.clientId}
              client_secret ${secretPlaceholder}
              scopes ${scopesLine}
              base_auth_url ${provider.baseAuthUrl}
              metadata_url ${provider.metadataUrl}
              delay_start ${toString provider.delayStart}
            ${optionalString (extra != "") extra}
            }''
        )
        sec.identityProviders;

      portalBlocks = mapAttrsToList
        (name: portal:
          let
            providerLines = map (providerName: "  enable identity provider ${providerName}") portal.identityProviders;
            cookieLines =
              let
                cookie = portal.cookie;
              in
              [ "  cookie insecure ${if cookie.insecure then "on" else "off"}" ]
              ++ (lib.optional (cookie.domain != null) "  cookie domain ${cookie.domain}")
              ++ (lib.optional (cookie.path != "") "  cookie path ${cookie.path}");
            contributionText =
              if builtins.hasAttr name portalClaimRoleTransforms then
                builtins.getAttr name portalClaimRoleTransforms
              else
                "";
            extraSnippets = filter (s: s != "") [ portal.extraConfig contributionText ];
            extra = concatStringsSep "\n" extraSnippets;
          in
          ''
              authentication portal ${name} {
              crypto default token lifetime ${toString portal.tokenLifetime}
            ${concatStringsSep "\n" providerLines}
            ${concatStringsSep "\n" cookieLines}
            ${optionalString (extra != "") extra}
            }''
        )
        sec.authenticationPortals;

      policyBlocks = mapAttrsToList
        (name: policy:
          let
            rolesLine = concatStringsSep " " policy.allowRoles;
            extra = policy.extraConfig;
          in
          ''
            authorization policy ${name} {
              set auth url ${policy.authUrl}
              allow roles ${rolesLine}
            ${optionalString policy.injectHeaders "  inject headers with claims"}
            ${optionalString (extra != "") extra}
            }''
        )
        sec.authorizationPolicies;

      innerSections = filter (s: s != "") (providerBlocks ++ portalBlocks ++ policyBlocks ++ [ sec.extraConfig ]);
      innerBlock = concatStringsSep "\n\n" innerSections;
      securityBody = if innerBlock == "" then "" else indentLines innerBlock;
      orderLine = optionalString sec.orderAuthenticateBeforeRespond "  order authenticate before respond\n\n";
    in
    if sec.enable then ''
      {
      ${orderLine}  security {
      ${securityBody}
        }
      }'' else "";
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

    security = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "caddy-security authentication/authorization integration";

          orderAuthenticateBeforeRespond = mkOption {
            type = types.bool;
            default = true;
            description = "Emit `order authenticate before respond` when the security block is enabled.";
          };

          identityProviders = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                driver = mkOption {
                  type = types.str;
                  default = "generic";
                  description = "caddy-security identity provider driver (e.g., generic, github, google).";
                };

                realm = mkOption {
                  type = types.str;
                  default = "default";
                  description = "Authentication realm label displayed to users.";
                };

                clientId = mkOption {
                  type = types.str;
                  description = "OIDC client ID registered with the upstream identity provider.";
                };

                clientSecretEnvVar = mkOption {
                  type = types.str;
                  description = "Environment variable containing the OIDC client secret (referenced as {$VARNAME} in the generated Caddyfile).";
                };

                scopes = mkOption {
                  type = types.listOf types.str;
                  default = [ "openid" "email" "profile" ];
                  description = "OAuth scopes requested from the upstream provider.";
                };

                baseAuthUrl = mkOption {
                  type = types.str;
                  description = "Base URL users should be redirected to for authentication (typically the public Pocket ID URL).";
                };

                metadataUrl = mkOption {
                  type = types.str;
                  description = "OIDC discovery metadata URL (usually <issuer>/.well-known/openid-configuration).";
                };

                delayStart = mkOption {
                  type = types.int;
                  default = 3;
                  description = "Seconds to delay before initializing the provider inside caddy-security (prevents bad gateway errors during boot).";
                };

                extraConfig = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Additional raw Caddyfile directives for this identity provider block.";
                };
              };
            });
            default = { };
            description = "Map of caddy-security identity providers keyed by provider name.";
          };

          authenticationPortals = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                identityProviders = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Identity providers to enable for this portal (must reference keys defined in identityProviders).";
                };

                tokenLifetime = mkOption {
                  type = types.int;
                  default = 86400;
                  description = "JWT lifetime (seconds) before re-authentication is required.";
                };

                cookie = mkOption {
                  type = types.submodule {
                    options = {
                      insecure = mkOption {
                        type = types.bool;
                        default = false;
                        description = "Whether to mark the caddy-security session cookie as insecure (HTTP). Leave false for HTTPS deployments.";
                      };

                      domain = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional cookie domain override.";
                      };

                      path = mkOption {
                        type = types.str;
                        default = "/";
                        description = "Cookie path scope.";
                      };
                    };
                  };
                  default = { };
                  description = "Cookie attributes for the authentication portal.";
                };

                extraConfig = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Additional raw directives for the authentication portal block.";
                };
              };
            });
            default = { };
            description = "Map of authentication portals keyed by portal name.";
          };

          authorizationPolicies = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                authUrl = mkOption {
                  type = types.str;
                  default = "/caddy-security/oauth2/generic";
                  description = "Authorization endpoint handled by the authentication portal (typically /caddy-security/oauth2/<provider>).";
                };

                allowRoles = mkOption {
                  type = types.listOf types.str;
                  default = [ "authenticated" ];
                  description = "List of roles/groups permitted to access this policy.";
                };

                injectHeaders = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether to inject identity claims into upstream headers (common for apps expecting X-Auth-* headers).";
                };

                extraConfig = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Additional raw directives for the authorization policy block.";
                };
              };
            });
            default = { };
            description = "Map of authorization policies keyed by policy name.";
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Additional raw configuration appended to the security block.";
          };
        };
      };
      default = {
        enable = false;
        identityProviders = { };
        authenticationPortals = { };
        authorizationPolicies = { };
        extraConfig = "";
      };
      description = "Settings for the caddy-security authentication portal/authorization plugin.";
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
            default = { };
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
      default = { };
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
                  default = { };
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
                        default = 15552000; # 6 months
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
                  default = { };
                  description = "HTTP Strict Transport Security settings";
                };
                customHeaders = mkOption {
                  type = types.attrsOf types.str;
                  default = { };
                  description = "Custom security headers at site level";
                  example = {
                    "X-Frame-Options" = "SAMEORIGIN";
                    "X-Content-Type-Options" = "nosniff";
                  };
                };
              };
            };
            default = { };
            description = "Security configuration";
          };

          caddySecurity = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                enable = mkEnableOption "caddy-security authentication enforcement for this host";

                portal = mkOption {
                  type = types.str;
                  default = "pocketid";
                  description = "Authentication portal name to use with `authenticate with <portal>`.";
                };

                policy = mkOption {
                  type = types.str;
                  default = "default";
                  description = "Authorization policy to apply with `authorize with <policy>`.";
                };

                claimRoles = mkOption {
                  type = types.listOf (types.submodule {
                    options = {
                      realm = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional realm override for this transform; defaults to the portal's realm.";
                      };

                      claim = mkOption {
                        type = types.str;
                        default = "groups";
                        description = "Claim to inspect (e.g., groups, email).";
                      };

                      value = mkOption {
                        type = types.str;
                        description = "Exact value the claim must match.";
                      };

                      role = mkOption {
                        type = types.str;
                        description = "Role to grant when the claim matches.";
                      };
                    };
                  });
                  default = [ ];
                  description = "Claim-based role grants contributed by this host.";
                };

                bypassPaths = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Exact path prefixes that should bypass authentication (append wildcard automatically).";
                  example = [ "/api" "/feed" ];
                };

                bypassResources = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Regex path matchers that should bypass authentication (converted to expression matchers).";
                  example = [ "^/api/system/status$" "^/rss/.*$" ];
                };

                allowedNetworks = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "CIDR ranges allowed to use bypass paths (empty = allow all, not recommended).";
                  example = [ "10.0.0.0/8" "192.168.0.0/16" ];
                };

                requireCredentials = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''Force the caddy-security portal to prompt for credentials even when a session cookie exists.
                    Useful for services that rely on HTTP Basic headers or need re-authentication.'';
                };
              };
            });
            default = null;
            description = "Protect this host with caddy-security (requires modules.services.caddy.security.enable).";
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

          # Cloudflare Tunnel integration
          cloudflare = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                enable = mkEnableOption "exposing this service via a Cloudflare Tunnel";
                tunnel = mkOption {
                  type = types.str;
                  description = "The name of the tunnel to expose this service through. Must match a key in `modules.services.cloudflared.tunnels`.";
                  example = "homelab";
                };

                dns = mkOption {
                  type = types.submodule {
                    options = {
                      register = mkOption {
                        type = types.bool;
                        default = true;
                        description = "If false, skip DNS automation for this host while still adding it to the tunnel ingress.";
                      };

                      zoneName = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional zone override for this host (defaults to the tunnel's zone).";
                      };

                      recordType = mkOption {
                        type = types.nullOr (types.enum [ "CNAME" ]);
                        default = null;
                        description = "DNS record type to create for this host (falls back to the tunnel default when null).";
                      };

                      proxied = mkOption {
                        type = types.nullOr types.bool;
                        default = null;
                        description = "Override whether Cloudflare should proxy this hostname.";
                      };

                      ttl = mkOption {
                        type = types.nullOr types.int;
                        default = null;
                        description = "Override TTL (seconds) for this hostname.";
                      };

                      target = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Override DNS record content (defaults to the tunnel's cfargotunnel endpoint).";
                      };

                      comment = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional comment/metadata attached to the DNS record when using the API.";
                      };
                    };
                  };
                  default = { };
                  description = "Per-host DNS registration overrides.";
                };
              };
            });
            default = null;
            description = "Declarative opt-in for Cloudflare Tunnel exposure.";
          };
        };
      });
      default = { };
      description = "Caddy virtual host configurations with structured backend and security options";
    };

  };

  config = mkIf cfg.enable {
    # Generate ACME TLS block based on configuration
    modules.services.caddy.acme.generateTlsBlock =
      let
        provider = cfg.acme.provider;
        resolversStr = concatStringsSep " " cfg.acme.resolvers;
      in
      ''
        # Use external DNS resolvers for ACME DNS-01 challenge verification
        tls {
          ${optionalString (provider != "http") "dns ${provider} {env.${cfg.acme.credentials.envVar}}"}
          ${optionalString (provider != "http") "resolvers ${resolversStr}"}
        }'';

    # Validation for virtual hosts
    assertions =
      # Virtual host validation
      (mapAttrsToList
        (name: vhost: {
          assertion = !vhost.enable || (vhost.backend != null || vhost.proxyTo != null);
          message = "Virtual host '${name}' must specify either 'backend' or 'proxyTo' when enabled.";
        })
        cfg.virtualHosts) ++
      (mapAttrsToList
        (name: vhost: {
          assertion = !vhost.enable || vhost.auth == null || (vhost.auth.user != "" && vhost.auth.passwordHashEnvVar != "");
          message = "Virtual host '${name}' has incomplete authentication configuration.";
        })
        cfg.virtualHosts) ++
      (mapAttrsToList
        (name: vhost: {
          assertion = !vhost.enable || vhost.caddySecurity == null || cfg.security.enable;
          message = "Virtual host '${name}' references caddy-security but modules.services.caddy.security.enable is false.";
        })
        cfg.virtualHosts) ++
      (mapAttrsToList
        (name: vhost: {
          assertion = !vhost.enable || vhost.caddySecurity == null || vhost.authelia == null;
          message = "Virtual host '${name}' cannot enable both Authelia and caddy-security simultaneously.";
        })
        cfg.virtualHosts) ++
      (optional (cfg.security.enable && cfg.security.identityProviders == { }) {
        assertion = false;
        message = "Caddy security is enabled but no identity providers are defined.";
      }) ++
      (optional (cfg.security.enable && cfg.security.authenticationPortals == { }) {
        assertion = false;
        message = "Caddy security is enabled but no authentication portals are defined.";
      }) ++
      (optional (cfg.security.enable && cfg.security.authorizationPolicies == { }) {
        assertion = false;
        message = "Caddy security is enabled but no authorization policies are defined.";
      }) ++
      # ACME credentials check
      [{
        assertion = cfg.acme.provider != "http" -> (cfg.acme.credentials.envVar != "");
        message = "Caddy ACME provider '${cfg.acme.provider}' requires credentials.envVar to be set.";
      }];

    # Add systemd dependencies on Authelia if any vhost uses it
    # Dynamically builds dependencies for all Authelia instances in use
    systemd.services.caddy = mkIf (autheliaEnabledVhosts != [ ]) {
      wants = map (instance: "authelia-${instance}.service") autheliaInstances;
      after = map (instance: "authelia-${instance}.service") autheliaInstances;
    };

    # Render the Caddyfile once and supply it via configFile so we fully control ordering
    services.caddy =
      let
        caddyfileText =
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
            vhostConfigs = filter (s: s != "") (mapAttrsToList
              (name: vhost:
                let
                  hasAuthelia = vhost.authelia != null && vhost.authelia.enable;
                  # Disable basic auth if Authelia is enabled
                  useBasicAuth = vhost.auth != null && !hasAuthelia;
                  useCaddySecurity = vhost.caddySecurity != null && vhost.caddySecurity.enable;
                  requireCredentials =
                    if useCaddySecurity then
                      vhost.caddySecurity.requireCredentials or false
                    else
                      false;
                  caddySecurityBypassPaths =
                    if useCaddySecurity then vhost.caddySecurity.bypassPaths else [ ];
                  caddySecurityBypassResources =
                    if useCaddySecurity then vhost.caddySecurity.bypassResources else [ ];
                  caddySecurityAllowedNetworks =
                    if useCaddySecurity then vhost.caddySecurity.allowedNetworks else [ ];
                  hasCaddySecurityBypassPaths = caddySecurityBypassPaths != [ ];
                  hasCaddySecurityBypassResources = caddySecurityBypassResources != [ ];
                  hasCaddySecurityBypass = hasCaddySecurityBypassPaths || hasCaddySecurityBypassResources;

                  # IP-restricted bypass configuration
                  hasBypassPaths = hasAuthelia && (vhost.authelia.bypassPaths or [ ]) != [ ];
                  hasNetworkRestrictions = hasAuthelia && (vhost.authelia.allowedNetworks or [ ]) != [ ];
                  useIpRestrictedBypass = hasBypassPaths && hasNetworkRestrictions;
                  bypassPathPatterns = map (path: "${path}*") (vhost.authelia.bypassPaths or [ ]);

                  backendUrl = buildBackendUrl vhost;
                  tlsTransport = generateTlsTransport vhost;
                  authMatcherName =
                    if useCaddySecurity then
                      "@caddy_security_${sanitizeForMatcher vhost.hostName}"
                    else
                      "";

                  reverseProxyBlockBase = ''
                    reverse_proxy ${backendUrl} {
                      ${tlsTransport}
                      ${vhost.reverseProxyBlock}
                    }
                  '';
                  reverseProxyBlockIndented = indentLines reverseProxyBlockBase;
                  reverseProxyBlockDoubleIndented = indentLines reverseProxyBlockIndented;

                  # Generate IP-restricted routes for bypass paths
                  ipRestrictedBypassConfig = optionalString useIpRestrictedBypass ''
                    # Matcher: API/bypass paths from internal networks only
                    @internalApi {
                      path ${concatStringsSep " " bypassPathPatterns}
                      remote_ip ${concatStringsSep " " vhost.authelia.allowedNetworks}
                    }

                    # Route: Direct access for trusted internal IPs (skip Authelia)
                    route @internalApi {
                      reverse_proxy ${backendUrl} {
                        ${tlsTransport}
                        ${vhost.reverseProxyBlock}
                      }
                    }

                  '';
                  escapeForExpression = str: lib.replaceStrings [ "\"" ] [ "\\\"" ] str;
                  caddySecurityBypassMatcher = "@caddy_security_bypass_${sanitizeForMatcher vhost.hostName}";
                  caddySecurityBypassConfig = optionalString (useCaddySecurity && hasCaddySecurityBypass) ''
                    # Matcher: Allowlisted paths that bypass caddy-security
                    ${caddySecurityBypassMatcher} {
                      ${optionalString hasCaddySecurityBypassPaths "path ${concatStringsSep " " (map (path: "${path}*") caddySecurityBypassPaths)}"}
                      ${concatStringsSep "\n                  " (map (pattern: "expression {regexp(path, \"${escapeForExpression pattern}\")}") caddySecurityBypassResources)}
                      ${optionalString (caddySecurityAllowedNetworks != []) "remote_ip ${concatStringsSep " " caddySecurityAllowedNetworks}"}
                    }

                    route ${caddySecurityBypassMatcher} {
                      reverse_proxy ${backendUrl} {
                        ${tlsTransport}
                        ${vhost.reverseProxyBlock}
                      }
                    }

                  '';

                  reverseProxyDirective =
                    if useCaddySecurity then ''
                                      ${authMatcherName} {
                                        path /caddy-security/* /oauth2/*
                                      }

                                      route ${authMatcherName} {
                                        authenticate with ${vhost.caddySecurity.portal}${optionalString requireCredentials " { credentials }"}
                                      }

                                      route /* {
                                        authorize with ${vhost.caddySecurity.policy}
                      ${reverseProxyBlockDoubleIndented}
                                      }
                    '' else reverseProxyBlockIndented;
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
                      ${ipRestrictedBypassConfig}${caddySecurityBypassConfig}${optionalString hasAuthelia (generateAutheliaForwardAuth vhost.authelia)}
                    # Reverse proxy to backend
                    ${reverseProxyDirective}
                    ${optionalString (vhost.extraConfig != "") "# Additional site-level directives\n                  ${vhost.extraConfig}"}
                  }
                '' else ""
              )
              cfg.virtualHosts);
          in
          concatStringsSep "\n\n" (filter (s: s != "") ([ securityBlock ] ++ vhostConfigs));
      in
      {
        enable = true;
        package = cfg.package;
        configFile = pkgs.writeText "caddy_config" caddyfileText;
      };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
