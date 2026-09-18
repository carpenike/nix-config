{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  plan = builtins.fromJSON (builtins.unsafeDiscardStringContext
    c.environment.etc."atrium/bootstrap/native-cutover.json".text);
  package = c.system.build.atriumNativePreparation;
  checks = {
    explicit-native-selection = c.services.atriumForge.adoption == {
      models = true;
      native = true;
      whiskey = false;
      whiskeyText = false;
    };
    owner-package-in-candidate-closure = package.name == "atrium-native-prepare"
      && lib.elem package c.environment.systemPackages;
    candidate-inputs-not-live-etc = lib.all
      (name: lib.hasPrefix "/nix/store/" plan.${name})
      [
        "native_template"
        "resolver_config"
        "enrollment"
        "tls_plan"
        "resolver_command"
        "native_bootstrap"
        "native_bootstrap_config"
        "finance_grants"
      ];
    retained-native-account-resolved-by-name = plan.native_identity
      == c.systemd.services.homelab-mcp.serviceConfig.User
      && plan.native_identity == "homelab-mcp";
    existing-resolver-and-trust-identities = plan.resolver_identity == {
      uid = 1060;
      gid = 1060;
    } && plan.trust_identity == {
      uid = 1061;
      gid = 1061;
    };
    retained-native-paths = plan.native_signing_key
      == c.systemd.services.homelab-mcp.environment.HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH
      && plan.native_oauth_database
      == c.systemd.services.homelab-mcp.environment.HOMELAB_MCP_OAUTH_STATE_DB_PATH
      && plan.native_oauth_database == "/var/lib/homelab-mcp/state.db";
    exact-installation-and-runtime-directory = plan.installation == "atrium-forge"
      && plan.policy_directory == "/var/lib/atrium-policy";
    exact-public-keys = plan.native_issuer == "https://mcp.holthome.net"
      && plan.native_jwks_url == "https://mcp.holthome.net/oauth/jwks.json"
      && plan.resolver_jwks_url == "https://atrium.holthome.net/.well-known/jwks.json";
    preparation-is-not-a-startup-unit = !(c.systemd.services ? atrium-native-prepare)
      && !(c.systemd.timers ? atrium-native-prepare);
    existing-initializers-remain-manual = lib.all
      (name: c.systemd.services.${name}.wantedBy == [ ]
        && c.systemd.services.${name}.requiredBy == [ ])
      [
        "atrium-initialize"
        "atrium-trust-initialize"
        "atrium-seed-policy"
        "atrium-model-resolver-initialize"
        "atrium-model-controller-initialize"
        "atrium-model-admission-initialize"
        "atrium-native-deny-initialize"
        "atrium-grant-finance-clients"
      ];
    native-startup-still-requires-approval = lib.all
      (name: lib.elem "/var/lib/atrium-policy/native-adoption.approved"
        c.systemd.services.${name}.unitConfig.AssertFileNotEmpty)
      [ "homelab-mcp" "atrium-native-policy" "atrium-native-settings" ];
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium native cutover wiring failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.native-cutover-wiring";
  runtime_gate_evidence = false;
  live_operations = false;
}
