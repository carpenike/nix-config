{ lib, registry }:
let
  identity = import ./identity.nix { inherit lib; };
  templates = registry.routeTemplates // registry.modelTemplates;
  seedGrant = templateId:
    let template = templates.${templateId}; in {
      id = "${templateId}.baseline";
      principal = "ryan";
      authority = identity.authority.id;
      subject = (builtins.head identity.bootstrap.identities).subject;
      expires_at = null;
      can_delegate = false;
      request = {
        inherit (template) domain instance;
        template_id = templateId;
        lifetime_seconds = template.maxLifetimeSeconds;
        scopes = template.scopes or [ ];
        permissions = template.permissions or [ ];
        models = template.models or [ ];
        routes = template.routes or [ ];
        budget =
          if template ? budget then {
            inherit (template.budget) usd;
            duration_seconds = template.budget.durationSeconds;
          } else null;
      };
    };
  seed = names: {
    schema_version = 1;
    administrator = "ryan";
    grants = map seedGrant names;
  };
in
{
  enrollment = identity.bootstrap // {
    principals = lib.mapAttrsToList
      (id: principal: {
        inherit id;
        display_name = principal.displayName;
        inherit (principal) kind roles;
      })
      registry.principals;
  };
  # Standing ordinary grants remain subordinate to fresh group evidence, native
  # rights and the current Nix ceiling. These files are not applied on boot.
  ordinary = seed [
    "cc.personal.ryan.data-read"
    "cc.family.holt.home-read"
    "cc.personal.ryan.whiskey"
    "cc.personal.ryan.sonnet-client"
    "cc.family.holt.haiku-client"
  ];
  opus = seed [ "cc.personal.ryan.opus-client" ];
  financeClients = seed [
    "cc.personal.ryan.finance"
    "cc.personal.ryan.scribe"
    "cc.personal.ryan.status"
    "cc.personal.ryan.money"
  ];
  # Kept out of the finance seed: that plan requires every grant domain to
  # match the Personal /mcp profile. This view is Family wing and owner-only.
  schoolClients = seed [
    "cc.family.holt.school"
  ];
  # The Home Services (/mcp) widening. The standing ordinary
  # `cc.personal.ryan.data-read.baseline` grant keeps its original
  # atrium-personal-read-only limits (seed-policy never rewrites a grant), and
  # the resolver requires a request to fit ONE grant. So a client signing in
  # with the widened view scopes needs this second, explicitly appended grant
  # on the same template. Apply once by hand after deploy, before reconnecting:
  #   systemctl start atrium-grant-home-services.service
  homeServicesClients = seed [ "cc.personal.ryan.data-read" ] // {
    grants = map (grant: grant // { id = "cc.personal.ryan.data-read.home-services"; })
      (seed [ "cc.personal.ryan.data-read" ]).grants;
  };
  # Kept out of the finance and school seeds. The overview is an ambit read,
  # not a Home MCP scope, and it stays owner-only.
  outingsClients = seed [
    "cc.family.holt.outings"
  ];
  # Infrastructure deploy. Kept out of financeClients: that list is asserted
  # exactly, and this capability must not ride a finance, ordinary, Family,
  # or unattended grant. The assistant's connector is granted the same way
  # Home Services is — a separate non-delegable seed, applied once by hand
  # (seed-policy never rewrites a grant):
  #   systemctl start atrium-grant-personal-deploy.service
  deployClients = seed [
    "cc.personal.ryan.deploy"
  ];
  groups = {
    schema_version = 1;
    authority = identity.authority.id;
    required_groups = builtins.attrNames registry.groups;
    principal_eligibility = lib.mapAttrs (_: principal: principal.groups or [ ]) registry.principals;
    membership_source = "fresh-verified-pocket-id-evidence";
    memberships_created = false;
    observations_seeded = false;
    operator_membership = {
      principal = "ryan";
      subject = (builtins.head identity.bootstrap.identities).subject;
      groups = registry.principals.ryan.groups;
    };
  };
}
