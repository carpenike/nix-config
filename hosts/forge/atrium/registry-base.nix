{ lib, homelabMcp }:
let
  identity = import ./identity.nix { inherit lib; };
  owner = {
    principals = [ "ryan" ];
    groups = [ ];
  };
  nativeView = route: scopes: {
    kind = "view";
    domain = "family:holt";
    ownerPrincipal = "ryan";
    deployment = "home-mcp";
    affinity = "remote";
    access = "read-write";
    authorityBinding = [ identity.authority.id ];
    inherit route scopes;
    audience = "home-mcp";
    acl = owner;
    deviceAcl.mode = "agnostic";
    permissions = [ ];
  };
  nativeTemplate = instance: scopes: {
    domain = "family:holt";
    inherit instance scopes;
    acl = owner;
    permissions = [ ];
    maxLifetimeSeconds = 900;
  };
in
identity.registry // {
  # This is a reviewed input fragment, not a complete/published N02 registry.
  # Model ownership and native adoption must be supplied explicitly.
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
  instances = {
    family-home-public = nativeView "/mcp" [ "admin" "hermes" "advisor" ] // {
      displayName = "Family wing native Home MCP";
    };
    family-home-hermes = nativeView "/cc/views/hermes" [ "hermes" ] // {
      displayName = "Family wing bounded Home MCP";
    };
  };
  routeTemplates = {
    family-home-admin = nativeTemplate "family-home-public" [ "admin" ];
    family-home-public-hermes = nativeTemplate "family-home-public" [ "hermes" ];
    family-home-public-advisor = nativeTemplate "family-home-public" [ "advisor" ];
    family-home-hermes = nativeTemplate "family-home-hermes" [ "hermes" ];
  };
}
