{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = import ./pre-adoption.nix { inherit inputs; };
  c = forge.config;
  packages = inputs.atrium.packages.${c.nixpkgs.hostPlatform.system};
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  identity = import ../../hosts/forge/atrium/identity.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix {
    inherit lib;
    groupEvidence = c.services.atriumForge.groupEvidence;
  };
  base = import ../../hosts/forge/atrium/registry-base.nix {
    inherit lib;
    homelabMcp = inputs.homelab-mcp;
  };
  ids = import ../../lib/service-uids.nix { };
  registry = c.services.atrium.registry;
  bootstrap = import ../../hosts/forge/atrium/bootstrap.nix { inherit lib registry; };
  models = import ../../hosts/forge/atrium/models.nix { inherit lib ids runtime registry; };
  disabled = (forge.extendModules {
    modules = [{ services.atriumForge.enable = lib.mkForce false; }];
  }).config;
  gateway = builtins.fromJSON (builtins.readFile
    (inputs.atrium + "/harness/version-candidates/litellm-1.100.1.json"));
  gatewayDocuments = inputs.atrium.lib.renderForGateway {
    inherit registry;
    nativeVersion = c.services.atrium.litellmVersion;
  };
  units = c.systemd.services;
  nativeCatalog = builtins.fromJSON (builtins.readFile base.catalogs.home-mcp.source);
  nativeVendor = builtins.fromJSON (builtins.readFile
    (inputs.homelab-mcp + "/vendor/atrium-artifacts.lock.json"));
  stateNames = [ "atrium-resolver" "atrium-trust" "atrium-policy" "atrium-reconciler" "atrium-model-gateway" ];
  modelAdopted = (forge.extendModules {
    modules = [{
      services.atriumForge.adoption.models = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  nativeAdopted = (forge.extendModules {
    modules = [{
      services.atriumForge.adoption.native = true;
      services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ];
    }];
  }).config;
  checks = {
    selected-application-pin = inputs.atrium.rev == pins.atrium;
    selected-native-pins = inputs.homelab-mcp.rev == pins.native
      && inputs.whiskey-whiskey-whiskey.rev == pins.consumer;
    native-vendor-matches-app = nativeVendor.revision == inputs.atrium.rev
      && nativeVendor.repository == "https://github.com/carpenike/atrium";
    explicit-gateway-version = gateway.kind == "atrium.litellm-version-candidate"
      && gateway.native_version == "v1.100.1"
      && c.services.atrium.litellmVersion == gateway.native_version;
    qualified-gateway-image = c.modules.services.litellm.image
      == builtins.replaceStrings [ "@" ] [ ":${gateway.native_version}@" ] gateway.image
      && runtime.adoption.models.image == c.modules.services.litellm.image;
    version-aware-desired-state = gatewayDocuments.litellm.native_version
      == c.services.atrium.litellmVersion;
    real-packages-installed = lib.elem packages.resolver c.environment.systemPackages
      && lib.elem packages.atrium-litellm-controller c.environment.systemPackages;
    actual-component-packages = c.services.atrium.runtime.resolver.package == packages.resolver
      && c.services.atrium.runtime.reconciler.package == packages.atrium-litellm-controller;
    explicit-identity-bootstrap-installed =
      builtins.fromJSON c.environment.etc."atrium/bootstrap/identity.json".text
      == bootstrap.enrollment
      && bootstrap.enrollment.identities == identity.bootstrap.identities;
    explicit-bootstrap-authority =
      builtins.fromJSON c.environment.etc."atrium/bootstrap/resolver.json".text == identity.settings
      && !identity.settings.isolated_harness
      && identity.registry.principals.ryan.groups == [ ];
    production-settings-installed =
      builtins.fromJSON c.environment.etc."atrium/runtime/atrium-resolver.json".text == runtime.resolver
      && builtins.fromJSON c.environment.etc."atrium/runtime/atrium-device-registration.json".text
      == runtime.registration
      && map (authority: builtins.removeAttrs authority [ "group_evidence" ])
        runtime.resolver.authorities == [ identity.authority ]
      && !runtime.resolver.isolated_harness
      && runtime.resolver.signing.issuer == "https://atrium.holthome.net";
    source-native-catalog = base.catalogs.home-mcp.source
      == inputs.homelab-mcp + "/tests/fixtures/atrium_catalog.generated.json"
      && nativeCatalog.kind == "atrium.source-catalog"
      && lib.all (scope: nativeCatalog.scopes ? ${scope})
      [ "admin" "advisor" "hermes" "atrium-personal-read" "atrium-family-read" ]
      && lib.elem "write" nativeCatalog.scopes.hermes.permissions
      && nativeCatalog.scopes.atrium-personal-read.permissions == [ "read" ]
      && nativeCatalog.scopes.atrium-family-read.permissions == [ "read" ]
      && lib.length nativeCatalog.scopes.atrium-personal-read.tools == 20
      && lib.length nativeCatalog.scopes.atrium-family-read.tools == 9
      && nativeCatalog.scopes.atrium-personal-read.resources == [ ]
      && nativeCatalog.scopes.atrium-family-read.resources == [ ];
    explicit-native-read-ceilings =
      registry.instances.personal-data-read.scopes == [ "atrium-personal-read" ]
      && registry.instances.family-home-read.scopes == [ "atrium-family-read" ]
      && registry.instances.personal-data-read.access == "read-only"
      && registry.instances.family-home-read.access == "read-only"
      && registry.instances.personal-data-read.domain == "personal:ryan"
      && registry.instances.personal-data-read.ownerPrincipal == "ryan"
      && registry.instances.personal-data-read.acl.groups == [ "atrium-personal-ryan" ]
      && lib.all
        (template: !lib.elem "admin" template.scopes)
        (builtins.attrValues registry.routeTemplates);
    reviewed-owner-only = builtins.attrNames base.principals == [ "ryan" ]
      && base.principals == identity.registry.principals
      && builtins.attrNames base.devices == [ "rymac" ]
      && base.devices.rymac.domains == [ "personal:ryan" "family:holt" ];
    complete-nix-registry-published = c.services.atrium.enable
      && registry.environment == "production"
      && builtins.length (builtins.attrNames c.services.atrium.generated) == 6
      && c.environment.etc ? "atrium/desired-state/resolver.json"
      && !(c.environment.etc ? "atrium/bootstrap/registry-base.json")
      && runtime.resolver.policy_path == "/etc/atrium/desired-state/resolver.json";
    groups-are-eligibility-not-observations =
      builtins.attrNames registry.groups == [ "atrium-family" "atrium-personal-ryan" ]
      && registry.principals.ryan.groups == [ "atrium-personal-ryan" "atrium-family" ]
      && registry.instances.personal-data-read.acl.principals == [ ]
      && registry.instances.family-home-read.acl.principals == [ ]
      && !bootstrap.groups.memberships_created && !bootstrap.groups.observations_seeded
      && gatewayDocuments.resolver.group_membership.nix_membership == "ceiling-only";
    no-real-child-or-extra-human = builtins.attrNames
      (lib.filterAttrs (_: principal: principal.kind == "human") registry.principals) == [ "ryan" ];
    ordinary-whiskey-native-ceiling = registry.instances.personal-whiskey.permissions == [ "read" "write" ]
      && registry.routeTemplates."cc.personal.ryan.whiskey".permissions == [ "read" "write" ]
      && gatewayDocuments.whiskey.operation_ceiling == "companion-intersect-native-per-operation"
      && !gatewayDocuments.whiskey.host_implies_write;
    explicit-adult-opus-selection = !lib.any
      (grant: grant.request.template_id == "cc.personal.ryan.opus-client")
      bootstrap.ordinary.grants
    && (builtins.head bootstrap.opus.grants).request.models == [ "cc.personal.ryan.opus" ]
    && units.atrium-select-opus.wantedBy == [ ]
    && lib.hasInfix "seed-policy --append" units.atrium-select-opus.serviceConfig.ExecStart;
    declared-cloud-models-only =
      registry.modelBackends."cc.personal.ryan.sonnet".model == "anthropic/claude-sonnet-5"
      && registry.modelBackends."cc.personal.ryan.opus".model == "anthropic/claude-opus-5"
      && registry.modelBackends."cc.family.holt.haiku".model == "anthropic/claude-haiku-4-5-20251001"
      && lib.all (alias: alias.fallbacks == [ ] && lib.length alias.backends == 1)
        (builtins.attrValues registry.aliases);
    new-owned-objects-only = lib.all (lib.hasPrefix "cc.")
      (builtins.attrNames registry.teams ++ builtins.attrNames registry.aliases
        ++ builtins.attrNames registry.modelTemplates ++ builtins.attrNames registry.modelBackends)
    && gatewayDocuments.litellm.ownership.unowned_objects == "leave-unchanged"
    && lib.all (model: !(lib.hasPrefix "cc." model.name)) c.modules.services.litellm.models;
    distinct-wing-provider-references =
      registry.serviceCredentials."cc.personal.ryan.anthropic".runtimePath
      != registry.serviceCredentials."cc.family.holt.anthropic".runtimePath
      && registry.serviceCredentials."cc.personal.ryan.anthropic".account == "atrium-personal-ryan-anthropic"
      && registry.serviceCredentials."cc.family.holt.anthropic".account == "atrium-family-holt-anthropic"
      && models.controllerCredentials.personal-anthropic != models.controllerCredentials.family-anthropic;
    approved-per-key-budget-periods = lib.all
      (template:
        if template.credentialKind == "client"
        then template.budget == { usd = 1; durationSeconds = 3600; }
          && template.maxLifetimeSeconds == 3600
        else template.budget == { usd = 2; durationSeconds = 86400; })
      (builtins.attrValues registry.modelTemplates);
    no-shell-filesystem-or-household-writes = !(registry.deployments ? sidecar)
      && lib.all (instance: instance.affinity == "remote") (builtins.attrValues registry.instances);
    real-runtime-commands = lib.hasPrefix "${lib.getExe packages.resolver} --config"
      units.atrium-resolver.serviceConfig.ExecStart
    && lib.hasSuffix "serve --port 18765" units.atrium-resolver.serviceConfig.ExecStart
    && lib.hasSuffix "serve-devices --port 18766"
      units.atrium-device-registration.serviceConfig.ExecStart;
    runtime-settings-restart-services = lib.all
      (name: units.${name}.restartTriggers
        == [ c.environment.etc."atrium/runtime/${name}.json".source c.services.atrium.generated.resolver ])
      [ "atrium-resolver" "atrium-device-registration" ];
    firewall-startup-is-required = lib.all
      (name: lib.elem "firewall.service" units.${name}.requires
        && lib.elem "firewall.service" units.${name}.after)
      [ "atrium-resolver" "atrium-device-registration" ];
    explicit-missing-state-refusal = lib.all
      (name: units.${name}.unitConfig.AssertPathExists == [
        "${runtime.paths.resolver}/foundation.initialized"
        "${runtime.paths.resolver}/resolver.sqlite3"
        runtime.resolver.policy_path
      ])
      [ "atrium-resolver" "atrium-device-registration" ];
    empty-state-is-not-bootstrap = lib.all
      (name: units.${name}.unitConfig.AssertFileNotEmpty
        == units.${name}.unitConfig.AssertPathExists)
      [ "atrium-resolver" "atrium-device-registration" ];
    initialization-is-manual = units.atrium-initialize.wantedBy == [ ]
      && units.atrium-trust-initialize.wantedBy == [ ]
      && !lib.elem "atrium-initialize.service" units.atrium-resolver.requires
      && !lib.elem "atrium-trust-initialize.service" units.atrium-resolver.requires;
    model-initialization-is-manual = lib.all
      (name: units.${name}.wantedBy == [ ])
      [
        "atrium-model-resolver-initialize"
        "atrium-model-controller-initialize"
        "atrium-model-admission-initialize"
        "atrium-seed-policy"
      ];
    initialization-never-resets = lib.hasInfix "test ! -e ${runtime.paths.resolver}/resolver.sqlite3"
      units.atrium-initialize.script
    && lib.hasInfix "--enrollment /etc/atrium/bootstrap/identity.json" units.atrium-initialize.script
    && lib.hasInfix "signing initialize" units.atrium-initialize.script
    && lib.hasSuffix "tls --plan /etc/atrium/bootstrap/tls-plan.json initialize"
      units.atrium-trust-initialize.serviceConfig.ExecStart;
    initialized-credentials-never-in-store = lib.all
      (source: lib.hasPrefix "${runtime.paths.trust}/" source && !lib.hasPrefix "/nix/store" source)
      (builtins.attrValues runtime.deviceCredentials)
    && units.atrium-resolver.serviceConfig.LoadCredential
      == lib.mapAttrsToList (name: path: "${name}:${path}") runtime.deviceCredentials;
    distinct-production-custody =
      c.users.users.atrium-resolver.uid == ids.atrium-resolver.uid
      && c.users.users.atrium-trust.uid == ids.atrium-trust.uid
      && c.users.users.atrium-registration.uid == ids.atrium-registration.uid
      && lib.length
        (lib.unique (map (name: c.users.users.${name}.uid)
          [ "atrium-resolver" "atrium-trust" "atrium-registration" ])) == 3
      && !lib.elem ids.atrium-resolver.uid [
        ids.atrium-resolver-fixture.uid
        ids.atrium-reconciler-fixture.uid
      ];
    direct-registration-tls = lib.hasInfix
      "TCP4-LISTEN:19443,bind=10.20.0.30,reuseaddr,fork TCP4:127.0.0.1:18766"
      units.atrium-registration-entry.serviceConfig.ExecStart
    && !(units.atrium-registration-entry.serviceConfig ? LoadCredential)
    && runtime.endpoints.registration == "https://forge.holthome.net:19443";
    protected-public-routes = lib.all
      (path: lib.hasInfix path c.modules.services.caddy.virtualHosts.atrium.extraConfig)
      [ "/cc/issue" "/v1/native-policy" "/v1/devices/register" ]
    && lib.hasInfix "respond @atrium_private 404"
      c.modules.services.caddy.virtualHosts.atrium.extraConfig;
    no-forwarded-identity = lib.all
      (header: lib.hasInfix "header_up -${header}"
        c.modules.services.caddy.virtualHosts.atrium.reverseProxyBlock)
      [ "Forwarded" "X-Forwarded-Client-Cert" "X-SSL-Client-Verify" "X-Principal" "X-Admin" ];
    protected-native-backchannels = lib.hasInfix
      "respond @atrium_service_only 404"
      c.modules.services.caddy.virtualHosts.homelab-mcp.extraConfig
    && !lib.hasInfix "/oauth/" c.modules.services.caddy.virtualHosts.homelab-mcp.extraConfig
    && lib.hasInfix "header_up -X-Forwarded-Client-Cert"
      c.modules.services.caddy.virtualHosts.homelab-mcp.reverseProxyBlock
    && lib.hasInfix "header_up -X-Principal"
      c.modules.services.caddy.virtualHosts.whiskeywhiskeywhiskey.reverseProxyBlock
    && !lib.hasInfix "header_up -Authorization"
      c.modules.services.caddy.virtualHosts.whiskeywhiskeywhiskey.reverseProxyBlock
    && !lib.hasInfix "header_up -X-Atrium-Grant"
      c.modules.services.caddy.virtualHosts.whiskeywhiskeywhiskey.reverseProxyBlock;
    lan-only-registration = lib.elem 19443 c.networking.firewall.interfaces.enp8s0.allowedTCPPorts
      && !lib.elem 19443 c.networking.firewall.allowedTCPPorts;
    loopback-owner-boundary = lib.all
      (value: lib.hasInfix value c.networking.firewall.extraCommands)
      [
        "--dport 18765 -m owner ! --uid-owner ${toString ids.caddy.uid}"
        "--dport 18766 -m owner ! --uid-owner ${toString ids.atrium-registration.uid}"
      ];
    explicit-separate-tls-identities = builtins.fromJSON
      c.environment.etc."atrium/bootstrap/tls-plan.json".text == runtime.tlsPlan
    && lib.length runtime.tlsPlan.authorities == 6
    && lib.length runtime.tlsPlan.certificates == 5
    && lib.all (cert: cert.purpose != "client" || cert.names == [ ]) runtime.tlsPlan.certificates;
    no-native-adoption = !(c.services.homelab-mcp.settings ? HOMELAB_MCP_ATRIUM_VIEW_POLICY)
      && !(c.services.whiskey-whiskey-whiskey.settings ? WWW_ATRIUM_CONFIG)
      && !(c.services.whiskey-whiskey-whiskey.settings ? WWW_ATRIUM_MODEL_CONFIG)
      && c.services.homelab-mcp.publicBaseUrl == runtime.endpoints.native
      && c.services.homelab-mcp.settings.HOMELAB_MCP_POCKETID_CLIENT_ID == "mcp"
      && runtime.resolver.home_mcp == null && runtime.resolver.litellm == null;
    no-unreviewed-reconciler = !c.services.atrium.runtime.reconciler.enable
      && !(units ? atrium-reconciler) && !(c.systemd.timers ? atrium-reconciler)
      && c.services.atrium.runtime.reconciler.credentials == { };
    explicit-adoption-requirements = builtins.fromJSON
      c.environment.etc."atrium/runtime/adoption.json".text == runtime.adoption
    && !runtime.adoption.home_mcp.enabled && !runtime.adoption.models.enabled
    && !runtime.adoption.whiskey.enabled;
    model-private-custody = modelAdopted.systemd.services.atrium-reconciler.serviceConfig.User == "atrium-reconciler"
      && modelAdopted.virtualisation.oci-containers.containers.litellm.user == "1064:1064"
      && modelAdopted.users.users.atrium-model-gateway.extraGroups == [ "atrium-model-metadata" ]
      && !lib.elem "atrium-whiskey-delivery" modelAdopted.users.users.atrium-model-gateway.extraGroups
      && lib.all
      (volume: !(lib.hasInfix "${models.private.controller}:" volume)
        && !(lib.hasInfix "${runtime.paths.resolver}:" volume)
        && !(lib.hasInfix "/run/atrium-delivery/" volume))
      modelAdopted.virtualisation.oci-containers.containers.litellm.volumes;
    live-producer-publications = models.resolver.publication_directory == models.exports.resolver
      && models.controller.association_snapshot == "${models.exports.resolver}/associations.json"
      && models.resolver.controller_inventory_file == "${models.exports.controller}/native-bindings.json"
      && models.admission.producers == [
      { id = "resolver"; kind = "resolver"; path = "${models.exports.resolver}/admission-associations.json"; publisher_uid = 1060; }
      { id = "controller-services"; kind = "controller-service"; path = "${models.exports.controller}/service-associations.json"; publisher_uid = 1063; }
    ]
      && models.metadataGroup.gid != models.deliveryGroup.gid
      && lib.hasInfix " --no-rotate" modelAdopted.systemd.services.atrium-reconciler.serviceConfig.ExecStart;
    gateway-private-transport = modelAdopted.modules.services.litellm.listenAddress == "127.0.0.1"
      && modelAdopted.modules.services.litellm.internalPort == 4100
      && modelAdopted.virtualisation.oci-containers.containers.litellm.ports == [ ]
      && lib.elem "--network=host" modelAdopted.virtualisation.oci-containers.containers.litellm.extraOptions
      && lib.elem "firewall.service" modelAdopted.systemd.services.podman-litellm.requires
      && modelAdopted.modules.services.litellm.models == c.modules.services.litellm.models
      && modelAdopted.modules.services.litellm.image == c.modules.services.litellm.image;
    exact-native-mtls-wiring =
      lib.hasInfix "serve-native-policy --port 18767"
        nativeAdopted.systemd.services.atrium-native-policy.serviceConfig.ExecStart
      && lib.hasInfix "native-policy --template"
        nativeAdopted.systemd.services.atrium-native-policy.serviceConfig.ExecStartPre
      && lib.elem "/run/atrium-native-mcp/native.env"
        nativeAdopted.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile
      && lib.hasInfix "tls_trust_pool file /run/credentials/caddy.service/atrium-native-ca"
        nativeAdopted.modules.services.caddy.virtualHosts.homelab-mcp.reverseProxyBlock
      && nativeAdopted.systemd.services.atrium-native-deny-initialize.wantedBy == [ ];
    native-deny-history-is-not-reinitialized = lib.all
      (path: lib.elem path nativeAdopted.systemd.services.homelab-mcp.unitConfig.AssertFileNotEmpty)
      [ "/var/lib/homelab-mcp/denial/owner.json" "/var/lib/homelab-mcp/denial/denial.sqlite" ];
    legacy-native-scope-maps-preserved =
      let
        original = builtins.fromJSON c.services.homelab-mcp.settings.HOMELAB_MCP_RESTRICTED_SCOPES;
        adopted = builtins.fromJSON nativeAdopted.services.homelab-mcp.settings.HOMELAB_MCP_RESTRICTED_SCOPES;
      in
      lib.all (name: original.${name} == adopted.${name}) (builtins.attrNames original);
    persistent-state-no-empty-restore = lib.all
      (name: c.modules.storage.datasets.services.${name}.mountpoint == "/var/lib/${name}"
        && !c.modules.storage.datasets.services.${name}.protection.allowEmptyBootstrap)
      stateNames;
    resolver-and-ca-custody-private =
      c.modules.storage.datasets.services.atrium-resolver.mode == "0700"
      && c.modules.storage.datasets.services.atrium-trust.mode == "0700"
      && c.modules.storage.datasets.services.atrium-policy.owner == "root"
      && c.modules.storage.datasets.services.atrium-policy.rootOwnedReason != null;
    encrypted-backup-tiers = lib.all
      (name: c.modules.services.backup.restic.jobs.${name}.enable
        && c.modules.services.backup.restic.jobs.${name}.useSnapshots
        && c.modules.services.backup.restic.jobs.${name}.repository == "nas-primary"
        && c.modules.services.backup.restic.jobs."${name}-offsite".repository == "r2-offsite"
        && c.modules.backup.sanoid.datasets."tank/services/${name}".autosnap)
      stateNames;
    health-is-not-admission = c.modules.services.gatus.contributions.atrium.url
      == "${runtime.endpoints.resolver}/healthz"
      && lib.hasInfix ''state="failed"'' c.modules.alerting.rules.atrium-trust-check-failed.expr;
    disable-removes-contributions = !(disabled.systemd.services ? atrium-resolver)
      && !(disabled.modules.storage.datasets.services ? atrium-resolver)
      && !(disabled.modules.services.caddy.virtualHosts ? atrium)
      && !(disabled.environment.etc ? "atrium/runtime/atrium-resolver.json");
  };
in
assert lib.assertMsg (lib.all (passed: passed) (builtins.attrValues checks))
  ("Atrium Forge runtime composition failed: " + builtins.toJSON (lib.filterAttrs (_: passed: !passed) checks));
{
  inherit checks;
  kind = "atrium.forge-runtime-composition";
  deployment_only = true;
  runtime_gate_evidence = false;
  live_activation = false;
  missing_policy_is_a_startup_failure = true;
  native_adoption = false;
  model_adoption = false;
}
