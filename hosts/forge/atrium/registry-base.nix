{ lib, homelabMcp }:
let
  identity = import ./identity.nix { inherit lib; };
in
identity.registry // {
  # Native catalog availability does not assign its data or scopes to a domain.
  # View ceilings, model ownership and adoption require explicit declarations.
  environment = "production";
  domains = {
    "personal:ryan".displayName = "Personal wing";
    "family:holt".displayName = "Family wing";
  };
  devices.rymac = {
    displayName = "Ryan's Mac";
    platform = "macos";
    principals = [ "ryan" ];
    domains = [ "personal:ryan" "family:holt" ];
  };
  catalogs.home-mcp = {
    adapter = "home-mcp";
    # The ordinary source-derived export, not the synthetic M03 catalog.
    source = homelabMcp + "/tests/fixtures/atrium_catalog.generated.json";
  };
  deployments.home-mcp = {
    adapter = "home-mcp";
    endpoint = "https://mcp.holthome.net";
    catalog = "home-mcp";
    viewEnforcement = "server-dispatch";
  };
}
