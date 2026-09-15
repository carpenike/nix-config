{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  forge = inputs.self.nixosConfigurations.forge;
  baseline = forge.config;
  select = module: (forge.extendModules {
    modules = [
      { services.atriumForge.groupEvidence.clientIds = [ "fixture-c10-public-client" ]; }
      module
    ];
  }).config;
  models = select { services.atriumForge.adoption.models = true; };
  native = select { services.atriumForge.adoption.native = true; };
  nativeResolver = builtins.fromJSON native.environment.etc."atrium/runtime/atrium-resolver.json".text;
  nativeBroker = nativeResolver.home_mcp.deployments.home-mcp;
  egress = builtins.fromJSON baseline.environment.etc."atrium/runtime/whiskey-egress.json".text;
  # These are test-only RFC5737 bindings. They are never host inventory or
  # deployed policy, and this check performs no network/native request.
  dynamic = {
    calendar = [ "calendar.atrium.invalid" ];
    media = [ "media.atrium.invalid" ];
    webpush = [ "push.atrium.invalid" ];
  };
  whiskey = select {
    services.atriumForge = {
      adoption = { models = true; whiskey = true; whiskeyText = true; };
      whiskeyEgress = {
        dynamicHosts = dynamic;
        dnsAddresses = [ "192.0.2.53" ];
        addresses = lib.genAttrs
          (egress.required_fixed_hosts ++ lib.concatLists (builtins.attrValues dynamic))
          (_: [ "198.51.100.10" ]);
      };
    };
  };
  gateway = models.virtualisation.oci-containers.containers.litellm;
  controller = models.systemd.services.atrium-reconciler;
  expectedHealth = url: "python3 -c " + lib.escapeShellArg
    ''import sys, urllib.request; sys.exit(0 if urllib.request.urlopen(${builtins.toJSON url}, timeout=5).status == 200 else 1)'';
  healthArguments = prefix: options: lib.filter (lib.hasPrefix prefix) options;
  legacyOptions = baseline.virtualisation.oci-containers.containers.litellm.extraOptions;
  checks = {
    native-default-unadopted = !(baseline.services.homelab-mcp.settings ? HOMELAB_MCP_ATRIUM_VIEW_POLICY);
    whiskey-default-unadopted = !(baseline.services.whiskey-whiskey-whiskey.settings ? WWW_ATRIUM_CONFIG);
    model-downgrade-refused = lib.elem "!/var/lib/atrium-policy/model-adoption.approved"
      baseline.systemd.services.podman-litellm.unitConfig.AssertPathExists;
    static-producer-identities = models.users.users.atrium-reconciler.uid == 1063
      && models.users.users.atrium-model-gateway.uid == 1064
      && controller.serviceConfig.User == "atrium-reconciler";
    separate-read-groups = models.users.groups.atrium-model-metadata.gid == 1065
      && models.users.groups.atrium-whiskey-delivery.gid == 1066
      && models.users.users.atrium-model-gateway.extraGroups == [ "atrium-model-metadata" ];
    private-gateway-process = gateway.user == "1064:1064"
      && lib.elem "--cap-drop=ALL" gateway.extraOptions
      && lib.elem "--network=host" gateway.extraOptions
      && gateway.ports == [ ]
      && models.modules.services.litellm.listenAddress == "127.0.0.1";
    existing-model-inventory-preserved = baseline.modules.services.litellm.models
      == models.modules.services.litellm.models;
    exact-image-preserved = gateway.image
      == "ghcr.io/berriai/litellm:v1.100.1@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf";
    health-via-protected-proxy = models.modules.services.gatus.contributions.litellm.url
      == "https://llm.holthome.net/health/liveliness";
    actual-regular-health-via-proxy = healthArguments "--health-cmd=" gateway.extraOptions
      == [ "--health-cmd=${expectedHealth "https://llm.holthome.net/health/liveliness"}" ];
    actual-startup-health-via-proxy = healthArguments "--health-startup-cmd=" gateway.extraOptions
      == [ "--health-startup-cmd=${expectedHealth "https://llm.holthome.net/health/liveliness"}" ];
    unadopted-regular-health-preserved = healthArguments "--health-cmd=" legacyOptions
      == [ "--health-cmd=${expectedHealth "http://127.0.0.1:4000/health/liveliness"}" ];
    unadopted-startup-health-preserved = healthArguments "--health-startup-cmd=" legacyOptions
      == [ "--health-startup-cmd=${expectedHealth "http://127.0.0.1:4000/health/liveliness"}" ];
    gateway-health-adds-no-firewall-bypass = lib.hasInfix
      "--dport 4100 -m owner ! --uid-owner 239 -j REJECT"
      models.networking.firewall.extraCommands
    && !lib.any
      (line: lib.hasInfix "--dport 4100" line && lib.hasInfix "--uid-owner 1064" line)
      (lib.splitString "\n" models.networking.firewall.extraCommands);
    admission-and-bootstrap-installed = gateway.environment.LITELLM_WORKER_STARTUP_HOOKS
      == "atrium_admission.bootstrap:install"
      && models.modules.services.litellm.extraLitellmSettings.callbacks == [ "atrium_admission.hook.admission" ];
    publishers-not-relayed = lib.elem "/run/atrium-publications/controller" controller.serviceConfig.ReadWritePaths
      && lib.elem "/run/atrium-publications/resolver" controller.serviceConfig.ReadOnlyPaths
      && lib.all
      (mount: !(lib.hasInfix "/var/lib/atrium-resolver:" mount)
        && !(lib.hasInfix "/var/lib/atrium-reconciler:" mount)
        && !(lib.hasInfix "/run/atrium-delivery/" mount))
      gateway.volumes;
    inference-secrets-remain-private = lib.elem
      "personal-anthropic:/run/secrets/atrium-personal-anthropic"
      controller.serviceConfig.LoadCredential
    && lib.elem "family-anthropic:/run/secrets/atrium-family-anthropic" controller.serviceConfig.LoadCredential
    && lib.elem "management:/run/secrets/atrium-litellm-controller-management" controller.serviceConfig.LoadCredential;
    unadopted-service-not-minted = lib.hasSuffix "--no-rotate" controller.serviceConfig.ExecStart;
    service-rotation-explicit = !(lib.hasInfix "--no-rotate"
      whiskey.systemd.services.atrium-reconciler.serviceConfig.ExecStart);
    service-key-read-live = whiskey.services.whiskey-whiskey-whiskey.settings.WWW_ATRIUM_MODEL_CONFIG
      == "/etc/atrium/runtime/whiskey-model.json"
      && lib.elem "/run/atrium-delivery/whiskey"
      whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.ReadOnlyPaths
      && lib.elem "/run/atrium-acknowledgements/whiskey"
      whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.ReadWritePaths
      && lib.all (value: !(lib.hasInfix "key.json" value))
      (whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.LoadCredential or [ ]);
    acknowledgement-custody = whiskey.users.users.whiskey-whiskey-whiskey.uid == 1067
      && whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.Group == "atrium-whiskey-delivery"
      && !whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.DynamicUser
      && !lib.elem "atrium-model-metadata" whiskey.users.users.whiskey-whiskey-whiskey.extraGroups;
    provider-text-fallback-removed = lib.elem "ANTHROPIC_API_KEY"
      whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.UnsetEnvironment
    && lib.elem "ANTHROPIC_MODEL"
      whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.UnsetEnvironment;
    native-migration-explicit = native.systemd.services.atrium-native-deny-initialize.wantedBy == [ ]
      && lib.elem "/run/atrium-native-mcp/native.env"
      native.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile
      && lib.all (file: lib.elem file native.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile)
      baseline.systemd.services.homelab-mcp.serviceConfig.EnvironmentFile;
    real-native-fingerprint-source = lib.hasInfix
      "--client-certificate /run/credentials/atrium-native-policy.service/policy-client-cert"
      native.systemd.services.atrium-native-policy.serviceConfig.ExecStartPre;
    canonical-native-issuance-identity = nativeBroker.endpoint
      == "https://mcp.holthome.net/cc/issue"
      && native.services.atrium.registry.deployments.home-mcp.endpoint == "https://mcp.holthome.net";
    separate-private-native-issuance-transport = nativeBroker.transport_endpoint
      == "https://127.0.0.1:9200/cc/issue"
      && nativeBroker.ca_certificate_path == "/run/credentials/atrium-resolver.service/native-ca"
      && nativeBroker.client_certificate_path == "/run/credentials/atrium-resolver.service/native-client-cert"
      && nativeBroker.client_private_key_path == "/run/credentials/atrium-resolver.service/native-client-key"
      && nativeBroker.verification_keys_path == "/run/credentials/atrium-resolver.service/native-jwks";
    direct-native-tls = lib.hasInfix "serve-native-policy --port 18767"
      native.systemd.services.atrium-native-policy.serviceConfig.ExecStart
    && lib.hasInfix "tls_trust_pool file /run/credentials/caddy.service/atrium-native-ca"
      native.modules.services.caddy.virtualHosts.homelab-mcp.reverseProxyBlock;
    native-history-required = lib.all
      (file: lib.elem file native.systemd.services.homelab-mcp.unitConfig.AssertFileNotEmpty)
      [ "/var/lib/homelab-mcp/denial/owner.json" "/var/lib/homelab-mcp/denial/denial.sqlite" ];
    whiskey-history-required = lib.all
      (file: lib.elem file whiskey.systemd.services.whiskey-whiskey-whiskey.unitConfig.AssertFileNotEmpty)
      [
        "/var/lib/whiskey-whiskey-whiskey/atrium-admission/owner.json"
        "/var/lib/whiskey-whiskey-whiskey/atrium-admission/admission.sqlite"
      ]
    && whiskey.systemd.services.atrium-whiskey-deny-initialize.wantedBy == [ ];
    image-and-native-settings-refresh = lib.elem "homelab-mcp.service"
      native.systemd.services.atrium-native-settings.partOf
    && lib.elem "whiskey-whiskey-whiskey.service" whiskey.systemd.services.atrium-whiskey-images.partOf
    && lib.elem "/run/atrium-whiskey-images/images.env"
      whiskey.systemd.services.whiskey-whiskey-whiskey.serviceConfig.EnvironmentFile;
    atomic-scoped-egress = lib.hasInfix "iptables-restore --wait --noflush"
      whiskey.systemd.services.atrium-whiskey-egress.script
    && lib.elem "atrium-whiskey-egress.service"
      whiskey.systemd.services.whiskey-whiskey-whiskey.requires;
    security-history-protection = native.modules.storage.datasets.services.homelab-mcp.protection.class == "critical"
      && !native.modules.storage.datasets.services.homelab-mcp.protection.allowEmptyBootstrap
      && native.modules.services.backup.restic.jobs.atrium-native-security-offsite.repository == "r2-offsite"
      && whiskey.modules.storage.datasets.services.whiskeywhiskeywhiskey.protection.class == "critical"
      && !whiskey.modules.storage.datasets.services.whiskeywhiskeywhiskey.protection.allowEmptyBootstrap
      && whiskey.modules.services.backup.restic.jobs.atrium-whiskey-security-offsite.repository == "r2-offsite";
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("Atrium adoption wiring failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.forge-adoption-wiring";
  synthetic_egress_bindings = true;
  complete_policy_validation = false;
  runtime_gate_evidence = false;
  live_operations = false;
}
