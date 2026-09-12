{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  packages = inputs.atrium.packages.${c.nixpkgs.hostPlatform.system};
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  identity = import ../../hosts/forge/atrium/identity.nix { inherit lib; };
  runtime = import ../../hosts/forge/atrium/runtime.nix { inherit lib; };
  base = import ../../hosts/forge/atrium/registry-base.nix {
    inherit lib;
    homelabMcp = inputs.homelab-mcp;
  };
  ids = import ../../lib/service-uids.nix { };
  disabled = (inputs.self.nixosConfigurations.forge.extendModules {
    modules = [{ services.atriumForge.enable = lib.mkForce false; }];
  }).config;
  gateway = builtins.fromJSON (builtins.readFile
    (inputs.atrium + "/harness/version-candidates/litellm-1.100.1.json"));
  gatewayDocuments = inputs.atrium.lib.renderForGateway {
    registry = import ../atrium/registry.nix { atrium = inputs.atrium; };
    nativeVersion = c.services.atrium.litellmVersion;
  };
  units = c.systemd.services;
  nativeCatalog = builtins.fromJSON (builtins.readFile base.catalogs.home-mcp.source);
  stateNames = [ "atrium-resolver" "atrium-trust" "atrium-policy" ];
  checks = {
    selected-application-pin = inputs.atrium.rev == pins.atrium;
    native-pins-unchanged = inputs.homelab-mcp.rev == pins.native
      && inputs.whiskey-whiskey-whiskey.rev == pins.consumer;
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
      builtins.fromJSON (builtins.readFile c.environment.etc."atrium/bootstrap/identity.json".source)
      == identity.bootstrap;
    explicit-bootstrap-authority =
      builtins.fromJSON c.environment.etc."atrium/bootstrap/resolver.json".text == identity.settings
      && !identity.settings.isolated_harness
      && identity.registry.principals.ryan.groups == [ ];
    production-settings-installed =
      builtins.fromJSON c.environment.etc."atrium/runtime/atrium-resolver.json".text == runtime.resolver
      && builtins.fromJSON c.environment.etc."atrium/runtime/atrium-device-registration.json".text
      == runtime.registration
      && runtime.resolver.authorities == [ identity.authority ]
      && !runtime.resolver.isolated_harness
      && runtime.resolver.signing.issuer == "https://atrium.holthome.net";
    source-native-catalog = base.catalogs.home-mcp.source
      == inputs.homelab-mcp + "/tests/fixtures/atrium_catalog.generated.json"
      && nativeCatalog.kind == "atrium.source-catalog"
      && builtins.attrNames nativeCatalog.scopes == [ "admin" "advisor" "hermes" ]
      && lib.elem "write" nativeCatalog.scopes.hermes.permissions
      && base.instances.family-home-hermes.access == "read-write";
    reviewed-owner-only = builtins.attrNames base.principals == [ "ryan" ]
      && base.principals == identity.registry.principals
      && builtins.attrNames base.devices == [ "rymac" ]
      && base.devices.rymac.domains == [ "personal:ryan" "family:holt" ];
    incomplete-registry-not-published = !c.services.atrium.enable
      && c.services.atrium.registry == null
      && c.services.atrium.generated == { }
      && !(c.environment.etc ? "atrium/desired-state/resolver.json")
      && !(base ? teams) && !(base ? modelBackends) && !(base ? serviceCredentials);
    real-runtime-commands = lib.hasPrefix "${lib.getExe packages.resolver} --config"
      units.atrium-resolver.serviceConfig.ExecStart
    && lib.hasSuffix "serve --port 18765" units.atrium-resolver.serviceConfig.ExecStart
    && lib.hasSuffix "serve-devices --port 18766"
      units.atrium-device-registration.serviceConfig.ExecStart;
    explicit-missing-state-refusal = lib.all
      (name: units.${name}.unitConfig.AssertPathExists == [
        "${runtime.paths.resolver}/foundation.initialized"
        "${runtime.paths.resolver}/resolver.sqlite3"
        runtime.resolver.policy_path
      ])
      [ "atrium-resolver" "atrium-device-registration" ];
    initialization-is-manual = units.atrium-initialize.wantedBy == [ ]
      && units.atrium-trust-initialize.wantedBy == [ ]
      && !lib.elem "atrium-initialize.service" units.atrium-resolver.requires
      && !lib.elem "atrium-trust-initialize.service" units.atrium-resolver.requires;
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
    persistent-state-no-empty-restore = lib.all
      (name: c.modules.storage.datasets.services.${name}.mountpoint == "/var/lib/${name}"
        && !c.modules.storage.datasets.services.${name}.protection.allowEmptyBootstrap)
      stateNames;
    resolver-and-ca-custody-private =
      c.modules.storage.datasets.services.atrium-resolver.mode == "0700"
      && c.modules.storage.datasets.services.atrium-trust.mode == "0700"
      && c.modules.storage.datasets.services.atrium-policy.owner == "root";
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
