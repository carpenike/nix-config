{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  enabled = forge.config;
  disabled = (forge.extendModules {
    modules = [{ services.atriumPwa.enable = lib.mkForce false; }];
  }).config;
  document = configuration: name:
    builtins.fromJSON configuration.environment.etc."atrium/${name}.json".text;
  client = document enabled "pwa/client-config";
  resolver = document enabled "runtime/atrium-resolver";
  whiskey = document enabled "runtime/whiskey";
  baselineWhiskey = document disabled "runtime/whiskey";
  checkedClients = [ "cc.atrium.operator" "cc.atrium.browser" ];
  checks = {
    package-is-app-owned = enabled.services.atriumPwa.package
      == inputs.atrium.packages.${enabled.nixpkgs.hostPlatform.system}.pwa;
    public-metadata-exact = client == {
      schema_version = 1;
      app_origin = "https://atrium.holthome.net";
      authority = "pocketid";
      issuer = "https://id.holthome.net";
      client_id = "cc.atrium.browser";
      redirect_uri = "https://atrium.holthome.net/auth/callback";
      resolver_resource = "https://atrium.holthome.net/resolver";
      native_resources = [{
        adapter = "whiskey";
        target_origin = "https://whiskeywhiskeywhiskey.org";
        resource = "https://whiskeywhiskeywhiskey.org/api/mcp";
      }];
    };
    both-declared-clients-admitted = enabled.services.atriumForge.groupEvidence.clientIds == checkedClients
      && (builtins.head resolver.authorities).group_evidence.client_ids == checkedClients;
    resolver-resource-preserved = client.resolver_resource == (builtins.head resolver.authorities).audience;
    native-resource-not-invented = (builtins.head client.native_resources).resource
      == enabled.services.whiskey-whiskey-whiskey.settings.WWW_EXTERNAL_AS_RESOURCE;
    native-browser-origin-is-exact = whiskey.browser_origin == client.app_origin
      && builtins.removeAttrs whiskey [ "browser_origin" ] == baselineWhiskey;
    caddy-consumes-real-generated-fragment = lib.hasPrefix
      "import ${enabled.services.atriumPwa.generated.caddy}\n"
      enabled.modules.services.caddy.virtualHosts.atrium.extraConfig;
    native-fallback-and-private-blocks-preserved =
      enabled.modules.services.caddy.virtualHosts.atrium.backend
      == disabled.modules.services.caddy.virtualHosts.atrium.backend
      && lib.hasInfix disabled.modules.services.caddy.virtualHosts.atrium.extraConfig
        enabled.modules.services.caddy.virtualHosts.atrium.extraConfig;
    no-cookie-proxy-auth = enabled.modules.services.caddy.virtualHosts.atrium.caddySecurity == null;
    unchanged-tunnel-and-firewall =
      enabled.modules.services.caddy.virtualHosts.atrium.cloudflare
      == disabled.modules.services.caddy.virtualHosts.atrium.cloudflare
      && enabled.networking.firewall.allowedTCPPorts == disabled.networking.firewall.allowedTCPPorts;
    no-policy-grant-or-identity-change = enabled.services.atrium.registry == disabled.services.atrium.registry
      && lib.all
      (name: enabled.environment.etc."atrium/bootstrap/${name}.json".text
        == disabled.environment.etc."atrium/bootstrap/${name}.json".text)
      [ "identity" "groups" "ordinary-grants" "finance-clients" "opus-selection" ];
    no-new-daemon-or-initialization =
      builtins.attrNames enabled.systemd.services == builtins.attrNames disabled.systemd.services;
    disabled-browser-restores-existing-shape = disabled.services.atriumPwa.generated == { }
      && !(disabled.environment.etc ? "atrium/pwa/client-config.json")
      && disabled.services.atriumForge.groupEvidence.clientIds == [ "cc.atrium.operator" ]
      && !(baselineWhiskey ? browser_origin);
    valid-host-assertions = lib.all (value: value.assertion) enabled.assertions;
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium browser wiring failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  runtime_gate_evidence = false;
  live_client_registration = false;
}
