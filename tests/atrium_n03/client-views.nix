{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = import ./pre-adoption.nix { inherit inputs; };
  baseline = forge.config;
  selected = inputs.self.nixosConfigurations.forge.config;
  native = (forge.extendModules {
    modules = [{
      services.atriumForge.adoption.native = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  registry = baseline.services.atrium.registry;
  bootstrap = import ../../hosts/forge/atrium/bootstrap.nix { inherit lib registry; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  catalog = builtins.fromJSON (builtins.readFile
    (inputs.homelab-mcp + "/tests/fixtures/atrium_catalog.generated.json"));
  scopes = [ "atrium-personal-read" "atrium-family-read" "atrium-family-school" ]
    ++ map (name: "atrium-personal-${name}") [ "finance" "scribe" "status" "money" "school" "recipes" "deploy" ];
  tools = config: builtins.fromJSON
    config.services.homelab-mcp.settings.HOMELAB_MCP_RESTRICTED_SCOPES;
  resources = config: builtins.fromJSON
    config.services.homelab-mcp.settings.HOMELAB_MCP_RESTRICTED_SCOPE_RESOURCES;
  legacyTools = tools baseline;
  nativeTools = tools native;
  legacyResources = resources baseline;
  nativeResources = resources native;
  legacy = baseline.services.hermes-agent;
  clients = native.services.hermes-agent;
  grantUnit = "atrium-grant-finance-clients";
  grantService = native.systemd.services.${grantUnit};
  grants = bootstrap.financeClients.grants;
  expectedGrants = map (name: "cc.personal.ryan.${name}") [ "finance" "scribe" "status" "money" ];
  checks = {
    exact-source-profiles = catalog.scopes.atrium-personal-finance.tools
      == lib.subtractLists
      [ "signal_send" "nixos_apply_config" "nixos_deploy_status" "homelab_list_status" ]
      catalog.scopes.advisor.tools
      && lib.length catalog.scopes.atrium-personal-finance.tools == 52
      && catalog.scopes.atrium-personal-scribe.tools
      == lib.remove "homelab_list_status" catalog.scopes.hermes.tools
      && lib.length catalog.scopes.atrium-personal-scribe.tools == 12
      && catalog.scopes.atrium-personal-status.tools == [ "homelab_list_status" ]
      && catalog.scopes.atrium-personal-status.resources == [ ]
      && catalog.scopes.atrium-personal-deploy.tools
      == [ "nixos_apply_config" "nixos_deploy_status" "homelab_list_status" ]
      && catalog.scopes.atrium-personal-deploy.resources == [ ]
      && catalog.scopes.atrium-personal-deploy.permissions == [ "read" "write" ]
      && catalog.scopes.atrium-personal-money.tools == [ "finances_overview" "finances_cashflow" "finances_balance_history" ]
      && catalog.scopes.atrium-personal-money.resources == [ ]
      && catalog.scopes.atrium-personal-money.permissions == [ "read" ]
      && catalog.scopes.atrium-family-school.tools == [ "school_parent_today" ]
      && catalog.scopes.atrium-family-school.resources == [ ]
      && catalog.scopes.atrium-family-school.permissions == [ "read" ]
      && !lib.elem "school_parent_today" catalog.scopes.hermes.tools
      && !lib.elem "school_parent_today" catalog.scopes.atrium-family-read.tools
      && !lib.elem "school_parent_today" catalog.scopes.advisor.tools
      && lib.all (tool: lib.hasPrefix "school_" tool) catalog.scopes.atrium-personal-school.tools
      && lib.elem "school_parent_today" catalog.scopes.atrium-personal-school.tools
      && catalog.scopes.atrium-personal-school.resources == [ ]
      && catalog.scopes.atrium-personal-school.permissions == [ "read" ]
      && catalog.scopes.atrium-personal-recipes.tools
      == [ "cooklang_list_recipes" "cooklang_get_recipe" "cooklang_search_federation" "cooklang_build_shopping_list" ]
      && catalog.scopes.atrium-personal-recipes.resources == [ ]
      && catalog.scopes.atrium-personal-recipes.permissions == [ "read" ]
      && lib.all (scope: !lib.any (lib.hasPrefix "school_") catalog.scopes.${scope}.tools)
      [ "hermes" "advisor" "atrium-family-read" "atrium-personal-scribe" "atrium-personal-status" "atrium-personal-money" "atrium-personal-deploy" ];
    honest-write-permissions = lib.all
      (scope: catalog.scopes.${scope}.permissions == [ "read" "write" ])
      [ "atrium-personal-finance" "atrium-personal-scribe" "atrium-personal-deploy" ]
    && catalog.scopes.atrium-personal-status.permissions == [ "read" ];
    ordinary-read-ceilings-preserved =
      lib.length catalog.scopes.atrium-personal-read.tools == 20
      && lib.length catalog.scopes.atrium-family-read.tools == 9
      && lib.all
        (scope: catalog.scopes.${scope}.permissions == [ "read" ]
        && catalog.scopes.${scope}.resources == [ ])
        [ "atrium-personal-read" "atrium-family-read" ]
      && registry.instances.personal-data-read.scopes == [ "atrium-personal-read" "atrium-personal-school" "atrium-personal-recipes" ]
      && registry.instances.family-home-read.scopes == [ "atrium-family-read" ]
      && registry.instances.personal-data-read.access == "read-only"
      && registry.instances.family-home-read.access == "read-only";
    exact-personal-targets = lib.all
      (name:
        let
          view = registry.instances."personal-${name}";
          template = registry.routeTemplates."cc.personal.ryan.${name}";
        in
        view.domain == "personal:ryan" && view.ownerPrincipal == "ryan"
        && view.deployment == "home-mcp" && view.kind == "view"
        && view.route == "/cc/views/personal-${name}"
        && view.scopes == [ "atrium-personal-${name}" ]
        && view.access == (if lib.elem name [ "status" "money" ] then "read-only" else "read-write")
        && view.authorityBinding == [ "pocketid" ]
        && template.domain == view.domain && template.instance == "personal-${name}"
        && template.scopes == view.scopes && template.acl == view.acl
        && template.permissions == [ ] && template.maxLifetimeSeconds == 900)
      [ "finance" "scribe" "status" "money" ];
    advisor-remains-group-backed = registry.instances.personal-finance.acl
      == { principals = [ ]; groups = [ "atrium-personal-ryan" ]; };
    automation-is-explicit-not-group-fallback = lib.all
      (name: registry.instances.${name}.acl == { principals = [ "ryan" ]; groups = [ ]; })
      [ "personal-scribe" "personal-status" "personal-deploy" ];
    money-is-owner-only = registry.instances.personal-money.acl
      == { principals = [ "ryan" ]; groups = [ ]; };
    deploy-is-read-write-owner-only =
      registry.instances.personal-deploy.domain == "personal:ryan"
      && registry.instances.personal-deploy.ownerPrincipal == "ryan"
      && registry.instances.personal-deploy.deployment == "home-mcp"
      && registry.instances.personal-deploy.kind == "view"
      && registry.instances.personal-deploy.route == "/cc/views/personal-deploy"
      && registry.instances.personal-deploy.scopes == [ "atrium-personal-deploy" ]
      && registry.instances.personal-deploy.access == "read-write"
      && registry.instances.personal-deploy.authorityBinding == [ "pocketid" ]
      && registry.instances.personal-deploy.acl == { principals = [ "ryan" ]; groups = [ ]; }
      && registry.routeTemplates."cc.personal.ryan.deploy".domain == "personal:ryan"
      && registry.routeTemplates."cc.personal.ryan.deploy".instance == "personal-deploy"
      && registry.routeTemplates."cc.personal.ryan.deploy".scopes == [ "atrium-personal-deploy" ]
      && registry.routeTemplates."cc.personal.ryan.deploy".permissions == [ ]
      && registry.routeTemplates."cc.personal.ryan.deploy".acl == registry.instances.personal-deploy.acl
      && registry.routeTemplates."cc.personal.ryan.deploy".maxLifetimeSeconds == 900
      && map (grant: grant.request.template_id) bootstrap.deployClients.grants == [ "cc.personal.ryan.deploy" ]
      && (builtins.head bootstrap.deployClients.grants).id == "cc.personal.ryan.deploy.baseline"
      && (builtins.head bootstrap.deployClients.grants).principal == "ryan"
      && !(builtins.head bootstrap.deployClients.grants).can_delegate
      && (builtins.head bootstrap.deployClients.grants).request.lifetime_seconds == 900
      && (builtins.head bootstrap.deployClients.grants).request.domain == "personal:ryan"
      && (builtins.head bootstrap.deployClients.grants).request.instance == "personal-deploy"
      && (builtins.head bootstrap.deployClients.grants).request.scopes == [ "atrium-personal-deploy" ]
      && (builtins.head bootstrap.deployClients.grants).request.permissions == [ ]
      && !lib.elem "cc.personal.ryan.deploy" (map (grant: grant.request.template_id) bootstrap.financeClients.grants)
      && !lib.elem "cc.personal.ryan.deploy" (map (grant: grant.request.template_id) bootstrap.ordinary.grants)
      && !lib.elem "cc.personal.ryan.deploy" (map (grant: grant.request.template_id) bootstrap.schoolClients.grants)
      && !lib.elem "cc.personal.ryan.deploy" (map (grant: grant.request.template_id) bootstrap.outingsClients.grants)
      && !lib.elem "atrium-personal-deploy" registry.instances.personal-data-read.scopes
      && !lib.elem "atrium-personal-deploy" registry.instances.personal-status.scopes
      && !lib.elem "atrium-personal-deploy" registry.instances.family-home-read.scopes
      && !lib.elem "atrium-personal-deploy" registry.instances.family-school.scopes;
    school-is-owner-family = registry.instances.family-school.domain == "family:holt"
      && registry.instances.family-school.route == "/cc/views/family-school"
      && registry.instances.family-school.scopes == [ "atrium-family-school" ]
      && registry.instances.family-school.access == "read-only"
      && registry.instances.family-school.ownerPrincipal == "ryan"
      && registry.instances.family-school.acl == { principals = [ "ryan" ]; groups = [ ]; }
      && registry.routeTemplates."cc.family.holt.school".domain == "family:holt"
      && registry.routeTemplates."cc.family.holt.school".instance == "family-school"
      && registry.routeTemplates."cc.family.holt.school".scopes == [ "atrium-family-school" ]
      && registry.routeTemplates."cc.family.holt.school".permissions == [ ]
      && registry.routeTemplates."cc.family.holt.school".acl == registry.instances.family-school.acl
      && map (grant: grant.request.template_id) bootstrap.schoolClients.grants == [ "cc.family.holt.school" ]
      && (builtins.head bootstrap.schoolClients.grants).principal == "ryan"
      && !(builtins.head bootstrap.schoolClients.grants).can_delegate
      && (builtins.head bootstrap.schoolClients.grants).request.domain == "family:holt"
      && (builtins.head bootstrap.schoolClients.grants).request.scopes == [ "atrium-family-school" ]
      && !lib.elem "cc.family.holt.school" (map (grant: grant.request.template_id) bootstrap.financeClients.grants)
      && !lib.elem "cc.family.holt.school" (map (grant: grant.request.template_id) bootstrap.ordinary.grants);
    home-services-grant-is-separate-personal-read = map (grant: grant.id) bootstrap.homeServicesClients.grants
      == [ "cc.personal.ryan.data-read.home-services" ]
      && (builtins.head bootstrap.homeServicesClients.grants).principal == "ryan"
      && !(builtins.head bootstrap.homeServicesClients.grants).can_delegate
      && (builtins.head bootstrap.homeServicesClients.grants).request.domain == "personal:ryan"
      && (builtins.head bootstrap.homeServicesClients.grants).request.instance == "personal-data-read"
      && (builtins.head bootstrap.homeServicesClients.grants).request.scopes
      == [ "atrium-personal-read" "atrium-personal-school" "atrium-personal-recipes" ]
      && (builtins.head bootstrap.homeServicesClients.grants).request.permissions == [ ]
      && !lib.elem "cc.personal.ryan.data-read.home-services" (map (grant: grant.id) bootstrap.ordinary.grants);
    outings-is-owner-family = registry.instances.family-outings.domain == "family:holt"
      && registry.instances.family-outings.deployment == "ambit"
      && registry.instances.family-outings.route == "/cc/views/family-outings"
      && registry.instances.family-outings.scopes == [ ]
      && registry.instances.family-outings.permissions == [ "read" ]
      && registry.instances.family-outings.access == "read-only"
      && registry.instances.family-outings.audience == "ambit"
      && registry.instances.family-outings.ownerPrincipal == "ryan"
      && registry.instances.family-outings.acl == { principals = [ "ryan" ]; groups = [ ]; }
      && registry.deployments.ambit.adapter == "ambit"
      && registry.deployments.ambit.endpoint == "https://ambit.holthome.net"
      && registry.routeTemplates."cc.family.holt.outings".instance == "family-outings"
      && registry.routeTemplates."cc.family.holt.outings".scopes == [ ]
      && registry.routeTemplates."cc.family.holt.outings".permissions == [ "read" ]
      && registry.routeTemplates."cc.family.holt.outings".acl == registry.instances.family-outings.acl
      && map (grant: grant.request.template_id) bootstrap.outingsClients.grants == [ "cc.family.holt.outings" ]
      && (builtins.head bootstrap.outingsClients.grants).principal == "ryan"
      && !(builtins.head bootstrap.outingsClients.grants).can_delegate
      && (builtins.head bootstrap.outingsClients.grants).request.domain == "family:holt"
      && (builtins.head bootstrap.outingsClients.grants).request.permissions == [ "read" ]
      && (builtins.head bootstrap.outingsClients.grants).request.scopes == [ ]
      && !lib.elem "cc.family.holt.outings" (map (grant: grant.request.template_id) bootstrap.financeClients.grants)
      && !lib.elem "cc.family.holt.outings" (map (grant: grant.request.template_id) bootstrap.schoolClients.grants)
      && !lib.elem "cc.family.holt.outings" (map (grant: grant.request.template_id) bootstrap.ordinary.grants)
      && !lib.elem "family-outings"
      (builtins.head runtime.nativePolicyTemplate.native_policy.adapters).views;
    ordinary-groups-still-required = lib.all
      (name: registry.instances.${name}.acl.principals == [ ])
      [ "personal-data-read" "family-home-read" ]
    && !bootstrap.groups.memberships_created && !bootstrap.groups.observations_seeded;
    policy-adapter-has-exact-current-views =
      (builtins.head runtime.nativePolicyTemplate.native_policy.adapters).views == [
        "personal-data-read"
        "family-home-read"
        "personal-finance"
        "personal-scribe"
        "personal-status"
        "personal-money"
        "personal-deploy"
        "family-school"
      ];
    default-public-resource-unchanged = runtime.native.resource == {
      id = "personal-data-read";
      domain = "personal:ryan";
      audience = "home-mcp";
      target = "https://mcp.holthome.net/mcp";
    };
    finance-grants-separate-from-ordinary =
      map (grant: grant.request.template_id) grants == expectedGrants
      && map (grant: grant.request.template_id) bootstrap.ordinary.grants == [
        "cc.personal.ryan.data-read"
        "cc.family.holt.home-read"
        "cc.personal.ryan.whiskey"
        "cc.personal.ryan.sonnet-client"
        "cc.family.holt.haiku-client"
      ]
      && builtins.fromJSON baseline.environment.etc."atrium/bootstrap/finance-clients.json".text
      == bootstrap.financeClients;
    grants-remain-bounded-nondelegable = lib.all
      (grant: grant.principal == "ryan" && grant.authority == "pocketid"
        && !grant.can_delegate && grant.request.lifetime_seconds == 900
        && grant.request.domain == "personal:ryan"
        && grant.request.permissions == [ ] && grant.request.models == [ ]
        && grant.request.routes == [ ] && grant.request.budget == null)
      grants;
    grant-append-is-manual = grantService.wantedBy == [ ]
      && grantService.requiredBy == [ ]
      && !(native.systemd.timers ? ${grantUnit})
      && lib.all
      (service: !lib.elem "${grantUnit}.service" (service.requires ++ service.wants))
      (builtins.attrValues native.systemd.services);
    grant-append-preserves-existing-state =
      grantService.serviceConfig.User == "atrium-resolver"
      && grantService.serviceConfig.PrivateNetwork
      && grantService.unitConfig.AssertFileNotEmpty == [
        "/var/lib/atrium-resolver/foundation.initialized"
        "/var/lib/atrium-resolver/resolver.sqlite3"
      ]
      && lib.hasSuffix
        "seed-policy --append --grants /etc/atrium/bootstrap/finance-clients.json"
        grantService.serviceConfig.ExecStart;
    deploy-grant-append-is-manual =
      let
        unit = "atrium-grant-personal-deploy";
        deployService = native.systemd.services.${unit};
      in
      deployService.wantedBy == [ ]
      && deployService.requiredBy == [ ]
      && !(native.systemd.timers ? ${unit})
      && lib.all
        (service: !lib.elem "${unit}.service" (service.requires ++ service.wants))
        (builtins.attrValues native.systemd.services)
      && deployService.serviceConfig.User == "atrium-resolver"
      && deployService.serviceConfig.PrivateNetwork
      && deployService.unitConfig.AssertFileNotEmpty == [
        "/var/lib/atrium-resolver/foundation.initialized"
        "/var/lib/atrium-resolver/resolver.sqlite3"
      ]
      && lib.hasSuffix
        "seed-policy --append --grants /etc/atrium/bootstrap/personal-deploy-clients.json"
        deployService.serviceConfig.ExecStart
      && builtins.fromJSON baseline.environment.etc."atrium/bootstrap/personal-deploy-clients.json".text
      == bootstrap.deployClients;
    legacy-dispatch-lists-unchanged = builtins.attrNames legacyTools == [ "advisor" "hermes" ]
      && legacyTools.advisor == catalog.scopes.advisor.tools
      && legacyTools.hermes == catalog.scopes.hermes.tools
      && nativeTools.advisor == legacyTools.advisor
      && nativeTools.hermes == legacyTools.hermes;
    adopted-dispatch-uses-source-profiles = lib.all
      (scope: nativeTools.${scope} == catalog.scopes.${scope}.tools)
      scopes
    && builtins.attrNames nativeTools == lib.sort builtins.lessThan
      ([ "advisor" "hermes" ] ++ scopes);
    adopted-resources-use-source-profiles = legacyResources == { advisor = [ "finances://" ]; }
      && nativeResources.advisor == legacyResources.advisor
      && lib.all (scope: nativeResources.${scope} == catalog.scopes.${scope}.resources) scopes
      && builtins.attrNames nativeResources == lib.sort builtins.lessThan ([ "advisor" ] ++ scopes);
    legacy-hermes-configuration-preserved = builtins.attrNames legacy.mcpServers
      == [ "holthome" "holthome-telegram" ]
      && lib.all
      (name: legacy.mcpServers.${name}.url == "https://mcp.holthome.net/mcp"
        && legacy.settings.mcp_servers.${name}.oauth.scope == "hermes")
      [ "holthome" "holthome-telegram" ]
      && legacy.settings.platform_toolsets == {
      cron = [ "safe" "holthome" ];
      signal = [ "hermes-signal" "holthome" ];
      telegram = [ "hermes-telegram" "holthome-telegram" ];
    };
    new-aliases-separate-token-caches = builtins.attrNames clients.mcpServers
      == [ "atrium-finance" "atrium-status" ]
      && clients.mcpServers.atrium-finance.url == "https://mcp.holthome.net/cc/views/personal-scribe"
      && clients.mcpServers.atrium-status.url == "https://mcp.holthome.net/cc/views/personal-status"
      && clients.settings.mcp_servers.atrium-finance.oauth.scope == "atrium-personal-scribe"
      && clients.settings.mcp_servers.atrium-status.oauth.scope == "atrium-personal-status";
    inactive-managed-aliases-explicitly-disabled = lib.all
      (name: clients.settings.mcp_servers.${name} == { enabled = false; })
      [ "holthome" "holthome-telegram" ]
    && lib.all (name: legacy.settings.mcp_servers.${name} == { enabled = false; })
      [ "atrium-finance" "atrium-status" ];
    startup-probes-use-routed-native-transport = lib.all
      (path:
        lib.hasInfix ''"https://mcp.holthome.net${path}"'' native.systemd.services.hermes-agent.preStart
          && lib.hasInfix ''"http://127.0.0.1:9200${path}"'' baseline.systemd.services.hermes-agent.preStart)
      [ "/healthz" "/mcp" ]
    && !(lib.hasInfix "http://127.0.0.1:9200" native.systemd.services.hermes-agent.preStart);
    confidential-client-and-callback-preserved = lib.all
      (pair: builtins.removeAttrs clients.settings.mcp_servers.${pair.new}.oauth [ "scope" ]
        == builtins.removeAttrs legacy.settings.mcp_servers.${pair.old}.oauth [ "scope" ])
      [
        { old = "holthome"; new = "atrium-finance"; }
        { old = "holthome-telegram"; new = "atrium-status"; }
      ];
    client-filters-match-server-boundaries =
      clients.mcpServers.atrium-finance.tools.include == catalog.scopes.atrium-personal-scribe.tools
      && clients.mcpServers.atrium-status.tools.include == catalog.scopes.atrium-personal-status.tools
      && !clients.mcpServers.atrium-finance.sampling.enabled
      && !clients.mcpServers.atrium-status.sampling.enabled;
    platform-toolsets-remain-separated = clients.settings.platform_toolsets == {
      cron = [ "safe" "atrium-finance" ];
      signal = [ "hermes-signal" "atrium-finance" ];
      telegram = [ "hermes-telegram" "atrium-status" ];
    };
    telegram-retired-without-disabling-signal =
      !clients.settings.gateway.platforms.telegram.enabled
      && !legacy.settings.gateway.platforms.telegram.enabled
      && !clients.settings.mcp_servers.atrium-status.enabled
      && !legacy.settings.mcp_servers.holthome-telegram.enabled
      && clients.settings.gateway.platforms.signal.enabled
      && legacy.settings.gateway.platforms.signal.enabled;
    model-and-scribe-guard-unchanged = clients.settings.model == legacy.settings.model
      && clients.settings.plugins == legacy.settings.plugins;
    selected-host-uses-bounded-native-clients = selected.services.atriumForge.adoption.native
      && selected.services.hermes-agent.mcpServers == clients.mcpServers
      && selected.services.hermes-agent.settings.platform_toolsets == clients.settings.platform_toolsets;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium bounded client views failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.forge-bounded-client-views";
  runtime_gate_evidence = false;
  live_operations = false;
}
