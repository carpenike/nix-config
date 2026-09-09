{ inputs, system ? "x86_64-linux" }:
let
  inherit (inputs.nixpkgs) lib;
  f = import ./fixture.nix { inherit inputs; };
  host = lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [ ./host.nix ];
  };
  c = host.config;
  units = [ "atrium-resolver" "atrium-device-registration" "atrium-native-policy" "homelab-mcp" "whiskey-whiskey-whiskey" "caddy" "atrium-registration-entry" ];
  checks = {
    isolated-host = c.networking.hostName == "atrium-n03-fixture";
    accepted-pins = inputs.atrium.rev == f.versions.atrium
      && inputs.homelab-mcp.rev == f.versions.native
      && inputs.whiskey-whiskey-whiskey.rev == f.versions.consumer;
    unchanged-native-origin = c.services.homelab-mcp.publicBaseUrl == f.generated.resolver.deployments.home-mcp.endpoint
      && f.resolver.home_mcp.deployments.home-mcp.endpoint == "${f.endpoints.native}/cc/issue";
    native-loopback-only = c.services.homelab-mcp.host == "127.0.0.1";
    whiskey-loopback-only = c.services.whiskey-whiskey-whiskey.host == "127.0.0.1"
      && !c.services.whiskey-whiskey-whiskey.openFirewall;
    no-public-host-firewall = c.networking.firewall.allowedTCPPorts == [ ];
    namespace-for-every-consumer = lib.all
      (unit: c.systemd.services.${unit}.serviceConfig.NetworkNamespacePath == f.namespacePath)
      units;
    empty-consumer-capabilities = lib.all
      (unit: c.systemd.services.${unit}.serviceConfig.CapabilityBoundingSet == [ "" ]
        && c.systemd.services.${unit}.serviceConfig.AmbientCapabilities == [ "" ])
      units;
    native-peer-not-proxy-assertion = !(lib.any
      (value: lib.hasInfix "native-client-key" value)
      c.systemd.services.caddy.serviceConfig.LoadCredential);
    actual-packages = c.services.atrium.runtime.resolver.package == inputs.atrium.packages.${system}.resolver
      && c.services.homelab-mcp.package == inputs.homelab-mcp.packages.${system}.default
      && c.services.whiskey-whiskey-whiskey.package == inputs.whiskey-whiskey-whiskey.packages.${system}.default;
    actual-device-cli = lib.hasInfix "serve-devices" c.systemd.services.atrium-device-registration.serviceConfig.ExecStart;
    actual-native-policy-cli = lib.hasInfix "serve-native-policy" c.systemd.services.atrium-native-policy.serviceConfig.ExecStart;
    private-native-policy-loopback = f.nativePolicyEndpoint == "https://127.0.0.1:${toString f.nativePolicyPort}/v1/native-policy"
      && !(lib.elem f.nativePolicyPort c.networking.firewall.allowedTCPPorts);
    resolver-owned-policy-state = c.systemd.services.atrium-native-policy.serviceConfig.User == "atrium-resolver"
      && c.systemd.services.atrium-native-policy.serviceConfig.Group == "atrium-resolver"
      && f.nativePolicy.state_directory == f.resolver.state_directory
      && f.nativePolicy.signing == f.resolver.signing;
    no-native-resolver-database-sharing = c.systemd.services.homelab-mcp.serviceConfig.User != "atrium-resolver"
      && !(lib.any (value: lib.hasInfix f.state.resolver value)
      c.systemd.services.homelab-mcp.serviceConfig.LoadCredential);
    actual-native-policy-client = builtins.fromJSON c.services.homelab-mcp.settings.HOMELAB_MCP_ATRIUM_POLICY == f.native.policy
      && f.native.policy.endpoint == f.nativePolicy.native_policy.audience;
    distinct-policy-peer-credentials = f.native.policy.client_private_key_path != f.resolver.home_mcp.deployments.home-mcp.client_private_key_path
      && !(lib.any (value: lib.hasInfix "policy-client-key" value || lib.hasInfix "native-client-key" value)
      c.systemd.services.caddy.serviceConfig.LoadCredential);
    explicit-policy-service-bindings =
      let adapter = builtins.head f.nativePolicy.native_policy.adapters; in
      adapter.native_issuer == f.endpoints.native
      && adapter.deployment == "home-mcp"
      && adapter.authorities.pocket-id-fixture == c.services.homelab-mcp.settings.HOMELAB_MCP_POCKETID_CLIENT_ID
      && lib.elem "family-home-public" adapter.views
      && adapter.certificates == [ ];
    private-policy-is-not-public-proxy = lib.hasInfix "respond @native_policy 404" (import ./caddy.nix { fixture = f; })
      && !(lib.hasInfix "18767" (import ./caddy.nix { fixture = f; }));
    policy-service-needs-no-broker-device-secrets = f.nativePolicy.home_mcp == null
      && f.nativePolicy.devices == null
      && !(lib.any (value: lib.hasInfix "device-ca-key" value || lib.hasInfix "native-client-key" value)
      c.systemd.services.atrium-native-policy.serviceConfig.LoadCredential);
    tls-preserving-registration-entry = lib.hasInfix "socat" c.systemd.services.atrium-registration-entry.serviceConfig.ExecStart
      && !(lib.hasInfix "OPENSSL" c.systemd.services.atrium-registration-entry.serviceConfig.ExecStart);
    no-live-mcp-subsystems = !c.services.homelab-mcp.onDemandDeploy.enable
      && !c.services.homelab-mcp.actualSidecar.enable && !c.services.homelab-mcp.financesExport.enable;
    rotating-model-path-not-credential-snapshot = c.services.whiskey-whiskey-whiskey.settings.WWW_ATRIUM_MODEL_CONFIG == "/etc/atrium/n03/whiskey-model.json"
      && !(lib.any (value: lib.hasInfix "delivery" value) c.systemd.services.whiskey-whiskey-whiskey.serviceConfig.LoadCredential);
    no-direct-anthropic-fallback = lib.elem "ANTHROPIC_API_KEY" c.systemd.services.whiskey-whiskey-whiskey.serviceConfig.UnsetEnvironment
      && lib.elem "ANTHROPIC_MODEL" c.systemd.services.whiskey-whiskey-whiskey.serviceConfig.UnsetEnvironment;
    public-policy-generated-once = builtins.length (builtins.attrNames c.services.atrium.generated) == 6;
    model-gap-is-closed-not-placeholder = f.resolver.litellm == null && !f.modelPlaneReady
      && !c.services.atrium.runtime.reconciler.enable;
    no-live-backup-notification-jobs = !(c.systemd.services ? restic-backups-atrium-n03)
      && !(c.systemd.services ? atrium-n03-notify);
    operations-use-repo-conventions =
      let
        operations = import ./operations.nix { fixture = f; inherit lib; };
      in
      !operations.backup_jobs_enabled && !operations.external_notifications_enabled
      && operations.alert_rules.atrium-resolver.restartChurn.unit == "atrium-resolver.service"
      && builtins.length operations.backup.state_sets == 3;
    valid-module-assertions = lib.all (item: item.assertion) c.assertions;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("N03 isolated checks failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.n03-isolated-unit-evaluation";
  runtime_gate_evidence = false;
  model_plane_ready = false;
  c8_adopted = true;
  check_count = builtins.length (builtins.attrNames checks);
}
