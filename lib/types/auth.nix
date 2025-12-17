# Static API key authentication type definition
{ lib }:
let
  inherit (lib) types mkOption;
in
{
  # Standalone static API key submodule for reuse across modules
  # This is extracted from caddySecuritySubmodule.staticApiKeys for use in other contexts
  staticApiKeySubmodule = types.submodule {
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
  };
}
