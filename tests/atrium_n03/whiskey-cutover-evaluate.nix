{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  c = inputs.self.nixosConfigurations.forge.config;
  plan = builtins.fromJSON (builtins.unsafeDiscardStringContext
    c.environment.etc."atrium/bootstrap/whiskey-cutover.json".text);
  selected = c.systemd.services.whiskey-whiskey-whiskey;
  maintenance = c.systemd.services."whiskey-www-maintenance@";
  network = c.systemd.services.atrium-whiskey-egress;
  refresh = c.systemd.services.atrium-whiskey-egress-refresh;
  metricsJob = lib.findFirst (job: job.job_name == "whiskeywhiskeywhiskey") null
    c.services.prometheus.scrapeConfigs;
  checks = {
    explicit-adapter-and-text-selection = c.services.atriumForge.adoption.whiskey
      && c.services.atriumForge.adoption.whiskeyText;
    immutable-owner-command = lib.elem c.system.build.atriumWhiskeyPreparation c.environment.systemPackages
      && lib.all (name: lib.hasPrefix "/nix/store/" plan.${name})
      [ "node" "bootstrap" "bootstrap_config" "network_helper" ];
    separate-existing-policy-dataset = plan.settings.deny.state_directory
      == "/var/lib/atrium-policy/whiskey-admission"
      && plan.legacy_deny_directory == "/var/lib/whiskey-whiskey-whiskey/atrium-admission"
      && c.modules.storage.datasets.services.atrium-policy.protection.class == "critical";
    unchanged-native-app-data = c.services.whiskey-whiskey-whiskey.dataDir
      == "/var/lib/whiskey-whiskey-whiskey"
      && selected.serviceConfig.StateDirectory == "whiskey-whiskey-whiskey";
    explicit-service-identity = plan.identity == {
      uid = 1067;
      gid = 1066;
      user = "whiskey-whiskey-whiskey";
      group = "atrium-whiskey-delivery";
    } && selected.serviceConfig.DynamicUser
      && maintenance.serviceConfig.DynamicUser
      && selected.serviceConfig.Group == maintenance.serviceConfig.Group;
    no-main-or-maintenance-direct-text-key = lib.all
      (unit: lib.elem "ANTHROPIC_API_KEY" unit.serviceConfig.UnsetEnvironment)
      [ selected maintenance ];
    no-token-snapshot = lib.all
      (unit: lib.elem "/run/atrium-delivery/whiskey" unit.serviceConfig.ReadOnlyPaths
        && lib.elem "/run/atrium-acknowledgements/whiskey" unit.serviceConfig.ReadWritePaths
        && !lib.any (item: lib.hasInfix "key.json" item) (unit.serviceConfig.LoadCredential or [ ]))
      [ selected maintenance ];
    original-image-credentials = plan.image_credentials == {
      image-openai = "/run/secrets/whiskey-whiskey-whiskey/openai_api_key";
      image-gemini = "/run/secrets/whiskey-whiskey-whiskey/gemini_api_key";
      image-openrouter = "/run/secrets/whiskey-whiskey-whiskey/openrouter_api_key";
    };
    exact-current-extra-destinations = c.services.atriumForge.whiskeyEgress.dynamicHosts == {
      calendar = [ "calendars.partiful.com" ];
      media = [ "whiskeywhiskeywhiskey.org" ];
      webpush = [ "web.push.apple.com" ];
    };
    no-anthropic-direct-destination = !lib.elem "api.anthropic.com" plan.egress.hosts;
    complete-address-refresh = lib.hasInfix "whiskey-network.py" network.script
      && lib.hasInfix "whiskey-network.py" refresh.serviceConfig.ExecStart
      && refresh.serviceConfig.CapabilityBoundingSet == [ "CAP_NET_ADMIN" ]
      && c.systemd.timers.atrium-whiskey-egress-refresh.timerConfig.OnUnitActiveSec == "1m";
    backend-remains-caddy-only = lib.hasInfix
      "--dport 3417 -m owner ! --uid-owner 239 -j REJECT"
      c.networking.firewall.extraCommands;
    metrics-use-private-caddy = metricsJob != null
      && (builtins.head metricsJob.static_configs).targets == [ "127.0.0.1:13417" ]
      && lib.hasInfix "http://127.0.0.1:13417" c.services.caddy.configFile.text
      && lib.hasInfix "method GET" c.modules.services.caddy.extraConfig
      && lib.hasInfix "path /metrics" c.modules.services.caddy.extraConfig;
    approval-not-generated-or-started = !(c.systemd.services ? atrium-whiskey-prepare)
      && !lib.any (rule: lib.hasInfix "whiskey-adoption.approved" rule) c.systemd.tmpfiles.rules
      && c.systemd.services.atrium-whiskey-deny-initialize.wantedBy == [ ]
      && lib.elem "/var/lib/atrium-policy/whiskey-adoption.approved" selected.unitConfig.AssertFileNotEmpty;
    no-ordinary-host-elevation = c.services.atrium.registry.instances.personal-whiskey.permissions
      == [ "read" "write" ];
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium Whiskey cutover wiring failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.whiskey-cutover-wiring";
  runtime_gate_evidence = false;
  live_operations = false;
}
