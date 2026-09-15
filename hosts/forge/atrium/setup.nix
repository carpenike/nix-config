{ lib, host, domain, sshUser, registry, bootstrap, runtime, models }:
let
  operator = bootstrap.groups.operator_membership;
  authority = registry.authorities.${bootstrap.groups.authority};
  bindings = lib.filter
    (binding: binding.principal == operator.principal
      && binding.authority == bootstrap.groups.authority)
    bootstrap.enrollment.identities;
  secret = name: purpose: { inherit name purpose; };
in
assert lib.assertMsg
  (lib.length bindings == 1
    && (builtins.head bindings).subject == operator.subject)
  "Atrium setup requires the exact enrolled operator subject for the group authority.";
assert lib.assertMsg
  (lib.all
    (name: builtins.hasAttr name registry.groups
      && lib.elem name registry.principals.${operator.principal}.groups)
    operator.groups)
  "Atrium setup group requests must remain within the explicit operator membership plan and registry ceiling.";
{
  schema_version = 1;
  inherit host;
  inherit (runtime) installation;
  pocket_id = {
    inherit (authority) issuer;
    resource = authority.audience;
    inherit (operator) principal subject;
    # Desired setup objects only; this manifest never configures admission.
    client_id = "cc.atrium.operator";
    redirect_uri = "http://127.0.0.1:18889/callback";
    access_token_minutes = 14;
    refresh_token_minutes = 60;
    groups = map
      (name: {
        inherit name;
        friendly_name = registry.groups.${name}.displayName;
        member_subjects = [ operator.subject ];
      })
      operator.groups;
  };
  deployment.admission_file = "hosts/forge/atrium/setup-admission.nix";
  initialization = {
    ssh_target = "${sshUser}@${host}.${domain}";
    units = [ "atrium-initialize" "atrium-trust-initialize" "atrium-seed-policy" ];
  };
  required_secrets = [
    (secret models.resolverCredentials.model-management
      "Resolver-only model management credential before explicit model adoption; not provisioned by setup.")
    (secret models.controllerCredentials.management
      "Controller-only model management credential before explicit model adoption; never an inference credential.")
    (secret models.controllerCredentials.personal-anthropic
      "Personal wing provider credential before explicit model adoption; distinct from Family and never copied to it.")
    (secret models.controllerCredentials.family-anthropic
      "Family wing provider credential before explicit model adoption; no shared client bearer.")
  ];
}
