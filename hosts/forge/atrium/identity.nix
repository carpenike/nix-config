{ lib }:
let
  bootstrap = builtins.fromJSON (builtins.readFile ./identity-bootstrap.json);
  authority = builtins.fromJSON (builtins.readFile ./pocketid-authority.json);
in
{
  inherit bootstrap authority;
  settings = {
    schema_version = 1;
    state_directory = "/var/lib/atrium-resolver";
    isolated_harness = false;
    authorities = [ authority ];
  };
  registry = {
    authorities.${authority.id} = {
      kind = "pocket-id";
      inherit (authority) issuer audience;
      jwksUri = authority.jwks_uri;
      tokenType = "access_token";
    };
    principals = lib.listToAttrs (map
      (principal: lib.nameValuePair principal.id {
        displayName = principal.display_name;
        inherit (principal) kind roles;
        groups = [ ];
        bindings = map
          (binding: { inherit (binding) authority subject; })
          (builtins.filter (binding: binding.principal == principal.id) bootstrap.identities);
      })
      bootstrap.principals);
  };
}
