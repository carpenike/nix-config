# Reverse proxy integration type definition (Caddy)
{ lib }:
let
  inherit (lib) types mkOption mkEnableOption;
in
{
  # Standardized reverse proxy integration submodule
  # Web services should use this type for automatic Caddy registration
  reverseProxySubmodule = types.submodule {
    options = {
      enable = mkEnableOption "reverse proxy integration";

      hostName = mkOption {
        type = types.str;
        description = "FQDN for this service";
        example = "service.holthome.net";
      };

      backend = mkOption {
        type = types.submodule {
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
        };
        description = "Structured backend configuration";
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
        description = "Basic authentication configuration";
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
              description = "Custom security headers";
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
            enable = mkEnableOption "caddy-security protection for this service";

            portal = mkOption {
              type = types.str;
              default = "pocketid";
              description = ''Name of the authentication portal configured in the global Caddy security block.'';
            };

            policy = mkOption {
              type = types.str;
              default = "default";
              description = ''Authorization policy to enforce for this service (maps to `authorization policy <name>` in Caddy).'';
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
              description = "Claim-based role grants contributed by this service.";
            };

            bypassPaths = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Exact path prefixes that should skip authentication (e.g., API endpoints using their own keys).";
              example = [ "/api" "/feed" ];
            };

            bypassResources = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Regex resources that should bypass caddy-security authorization checks.";
              example = [ "^/api/system/status$" "^/rss/.*$" ];
            };

            allowedNetworks = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "List of CIDR ranges permitted to use bypassed paths; leave empty to allow any source (not recommended).";
              example = [ "10.0.0.0/8" "192.168.0.0/16" ];
            };

            requireCredentials = mkOption {
              type = types.bool;
              default = false;
              description = ''Force caddy-security to prompt for credentials even when an SSO session exists.
                Useful for services (like Sonarr) that expect HTTP Basic headers.'';
            };

            # Static S2S API keys (pre-defined, for automation like GitHub Actions)
            staticApiKeys = mkOption {
              type = types.listOf (types.submodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Identifier for this API key (used in audit headers and logging).";
                    example = "github-actions";
                  };

                  envVar = mkOption {
                    type = types.str;
                    description = "Environment variable name containing the API key secret.";
                    example = "PROMETHEUS_GITHUB_API_KEY";
                  };

                  headerName = mkOption {
                    type = types.str;
                    default = "X-Api-Key";
                    description = "HTTP header name to check for the API key.";
                  };

                  paths = mkOption {
                    type = types.nullOr (types.listOf types.str);
                    default = null;
                    description = ''Path prefixes this key is valid for. If null, key is valid for all paths.
                      Use for path-scoped authentication (e.g., API endpoints only).'';
                    example = [ "/api" "/v1" ];
                  };

                  allowedNetworks = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "CIDR ranges this key is valid from. Empty means any source.";
                    example = [ "10.0.0.0/8" ];
                  };

                  injectAuthHeader = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Inject X-Auth-Source header with key name for auditing.";
                  };
                };
              });
              default = [ ];
              description = ''Static API keys for system-to-system authentication. These bypass the
                caddy-security flow entirely and are validated using native Caddy header matchers.
                Keys are pre-defined in SOPS and referenced via environment variables.'';
            };
          };
        });
        default = null;
        description = ''Protect this reverse proxy definition with the caddy-security plugin. Requires `modules.services.caddy.security.enable = true`.'';
      };

      reverseProxyBlock = mkOption {
        type = types.lines;
        default = "";
        description = "Directives for inside the reverse_proxy block (e.g., header_up)";
        example = ''
          header_up X-Api-Key {$MY_API_KEY}
          header_up Host {upstream_hostport}
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Additional Caddy directives for this virtual host";
      };
    };
  };
}
