# Caddy Helper Functions for DRY Service Registration
#
# Provides specialized helpers following the backup-helpers.nix pattern
# to reduce boilerplate and enforce consistent security configurations.
#
# Usage:
#   let
#     caddyHelpers = import ../lib/caddy-helpers.nix { inherit lib; };
#   in {
#     config = lib.mkIf cfg.enable (caddyHelpers.mkPublicService {
#       name = "myservice";
#       subdomain = "myservice";
#       port = 8080;
#     });
#   }

{ lib }:

with lib;

{
  # Register a basic public service (no authentication)
  # Use for public-facing services or those with their own auth
  mkPublicService = {
    name,
    subdomain,
    port,
    domain ? null,
    scheme ? "http",
    securityLevel ? "standard",  # "minimal" | "standard" | "high"
    condition ? true,
  }:
    mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";

        backend = {
          inherit scheme port;
          host = "localhost";
          tls = {
            verify = true;
            acknowledgeInsecure = false;
          };
        };

        # Security headers based on level
        securityHeaders =
          if securityLevel == "minimal" then {
            X-Content-Type-Options = "nosniff";
          }
          else if securityLevel == "standard" then {
            X-Frame-Options = "SAMEORIGIN";
            X-Content-Type-Options = "nosniff";
            X-XSS-Protection = "1; mode=block";
          }
          else if securityLevel == "high" then {
            X-Frame-Options = "DENY";
            X-Content-Type-Options = "nosniff";
            X-XSS-Protection = "1; mode=block";
            Referrer-Policy = "strict-origin-when-cross-origin";
            Permissions-Policy = "geolocation=(), microphone=(), camera=()";
          }
          else {};

        security.hsts = {
          enable = securityLevel == "high" || securityLevel == "standard";
          maxAge = if securityLevel == "high" then 31536000 else 15552000;  # 1yr vs 6mo
          includeSubDomains = true;
          preload = securityLevel == "high";
        };
      };
    };

  # Register an authenticated service with basic auth
  # Use for internal admin interfaces
  mkAuthenticatedService = {
    name,
    subdomain,
    port,
    domain ? null,
    scheme ? "http",
    authUser,
    authPasswordHashEnvVar,
    condition ? true,
  }:
    mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";

        backend = {
          inherit scheme port;
          host = "localhost";
          tls = {
            verify = true;
            acknowledgeInsecure = false;
          };
        };

        auth = {
          user = authUser;
          passwordHashEnvVar = authPasswordHashEnvVar;
        };

        # High security by default for authenticated services
        securityHeaders = {
          X-Frame-Options = "DENY";
          X-Content-Type-Options = "nosniff";
          X-XSS-Protection = "1; mode=block";
          Referrer-Policy = "strict-origin-when-cross-origin";
          Permissions-Policy = "geolocation=(), microphone=(), camera=()";
        };

        security.hsts = {
          enable = true;
          maxAge = 31536000;  # 1 year
          includeSubDomains = true;
          preload = false;
        };
      };
    };

  # Register a secure web application with opinionated security defaults
  # Use for SPAs, web UIs, and interactive applications
  mkSecureWebApp = {
    name,
    subdomain,
    port,
    domain ? null,
    scheme ? "http",
    requireAuth ? false,
    authUser ? "admin",
    authPasswordHashEnvVar ? null,
    allowFraming ? false,  # Set true for embedding in iframes
    condition ? true,
  }:
    mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";

        backend = {
          inherit scheme port;
          host = "localhost";
          tls = {
            verify = true;
            acknowledgeInsecure = false;
          };
        };

        auth = mkIf requireAuth {
          user = authUser;
          passwordHashEnvVar = authPasswordHashEnvVar;
        };

        # Comprehensive security headers for web apps
        securityHeaders = {
          X-Frame-Options = if allowFraming then "SAMEORIGIN" else "DENY";
          X-Content-Type-Options = "nosniff";
          X-XSS-Protection = "1; mode=block";
          Referrer-Policy = "strict-origin-when-cross-origin";
          Permissions-Policy = "geolocation=(), microphone=(), camera=()";
          Content-Security-Policy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'";
        };

        security.hsts = {
          enable = true;
          maxAge = 31536000;
          includeSubDomains = true;
          preload = false;
        };
      };
    };

  # Register a service with an HTTPS backend (e.g., Omada, Unifi)
  # Handles TLS backend configuration safely
  mkHttpsBackendService = {
    name,
    subdomain,
    port,
    domain ? null,
    verifyTls ? true,  # Require explicit opt-out
    acknowledgeInsecure ? false,  # Required when verifyTls = false
    sni ? null,
    caFile ? null,
    securityLevel ? "standard",
    condition ? true,
  }:
    mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";

        backend = {
          scheme = "https";
          inherit port;
          host = "localhost";
          tls = {
            verify = verifyTls;
            inherit acknowledgeInsecure sni caFile;
          };
        };

        securityHeaders =
          if securityLevel == "standard" then {
            X-Frame-Options = "SAMEORIGIN";
            X-Content-Type-Options = "nosniff";
            X-XSS-Protection = "1; mode=block";
          }
          else if securityLevel == "high" then {
            X-Frame-Options = "DENY";
            X-Content-Type-Options = "nosniff";
            X-XSS-Protection = "1; mode=block";
            Referrer-Policy = "strict-origin-when-cross-origin";
          }
          else {};

        security.hsts = {
          enable = securityLevel != "minimal";
          maxAge = 15552000;
          includeSubDomains = true;
        };
      };
    };

  # Legacy helper for backward compatibility with register-vhost.nix
  # Prefer the specialized helpers above for new services
  registerVirtualHost = {
    name,
    subdomain,
    port,
    domain ? null,
    httpsBackend ? false,
    auth ? null,
    headers ? "",
    extraConfig ? "",
    condition ? true,
  }:
    mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";

        backend = {
          scheme = if httpsBackend then "https" else "http";
          inherit port;
          host = "localhost";
          tls = mkIf httpsBackend {
            verify = false;  # Legacy behavior
            acknowledgeInsecure = true;  # Auto-acknowledge for backward compat
          };
        };

        # Legacy string-based headers (deprecated)
        vendorExtensions.caddy = {
          reverseProxyBlock = headers;
          extraConfig = extraConfig;
        };

        inherit auth;
      };
    };
}
