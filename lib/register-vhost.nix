# Helper function to register a service with the reverse proxy
#
# This provides a DRY way for both service modules and host-level configs
# to declaratively register their reverse proxy requirements.
#
# Usage in a service module:
#   config = lib.mkIf cfg.enable (lib.mkMerge [
#     (registerVirtualHost {
#       name = "myservice";
#       subdomain = cfg.reverseProxy.subdomain;
#       port = cfg.port;
#       httpsBackend = false;
#       auth = cfg.reverseProxy.auth;
#     })
#     { /* rest of service config */ }
#   ]);
#
# Usage in a host config (e.g., hosts/forge/dispatcharr.nix):
#   config = lib.mkMerge [
#     (registerVirtualHost {
#       name = "dispatcharr";
#       subdomain = "dispatcharr";
#       port = 9191;
#       domain = config.networking.domain;
#     })
#     { /* rest of service config */ }
#   ];

{ lib }:

{
  # Register a virtual host with the reverse proxy registry
  #
  # Parameters:
  #   name: Unique identifier for this virtual host (used as attribute key)
  #   subdomain: Subdomain portion of the hostname
  #   port: Backend port number
  #   domain: (optional) Override the default domain
  #   httpsBackend: (optional, default: false) Whether backend uses HTTPS
  #   auth: (optional) Authentication configuration { user, passwordHashEnvVar }
  #   headers: (optional) Additional header directives
  #   extraConfig: (optional) Extra Caddyfile directives
  #   condition: (optional, default: true) Condition to enable registration
  registerVirtualHost =
    { name
    , subdomain
    , port
    , domain ? null
    , httpsBackend ? false
    , auth ? null
    , headers ? ""
    , extraConfig ? ""
    , condition ? true
    ,
    }:
    lib.mkIf condition {
      modules.reverseProxy.virtualHosts.${name} = {
        enable = true;
        hostName =
          if domain != null
          then "${subdomain}.${domain}"
          else lib.mkDefault "${subdomain}.\${config.modules.reverseProxy.domain}";
        proxyTo = "localhost:${toString port}";
        inherit httpsBackend headers auth extraConfig;
      };
    };
}
