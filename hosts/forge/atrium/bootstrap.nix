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
