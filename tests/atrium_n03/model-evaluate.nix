{ inputs, system ? "x86_64-linux" }:
let
  inherit (inputs.nixpkgs) lib;
  f = import ./fixture.nix { inherit inputs; };
  m = f.models;
  c = (lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [ ./host.nix ];
  }).config;
  enabled = (lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [ ./host.nix { services.atriumN03Models.enable = true; } ];
  }).config;
  activeFixture = import ./fixture.nix { inherit inputs; enableModels = true; };
  gateway = c.virtualisation.oci-containers.containers.atrium-n03-models;
  includes = name: lib.elem m.metadataGroup.name c.users.users.${name}.extraGroups;
  liveCaddy = import ./caddy.nix { fixture = f; };
  previewCaddy = import ./caddy.nix { fixture = f // { modelPlaneReady = true; }; };
  cases = builtins.fromJSON (builtins.readFile ./model-cases.json);
  checks = {
    disabled-without-explicit-opt-in = !f.modelPlaneReady && m.acceptedPublisherPins.verified
      && !c.services.atrium.runtime.reconciler.enable
      && !c.services.atriumLitellmAdmission.enable
      && !c.systemd.services.podman-atrium-n03-models.enable
      && !c.systemd.services.atrium-n03-model-inputs.enable
      && !c.systemd.services.atrium-n03-admission-settings.enable
      && !c.systemd.timers.atrium-reconciler.enable && !gateway.autoStart;
    accepted-publisher-inputs = m.acceptedPublisherPins.atrium == inputs.atrium.rev
      && m.acceptedPublisherPins.controller == "ca0c0de92c2a70eae412706ccf3f68f3bcdc9b0b";
    explicit-opt-in-enables-real-model-actors = activeFixture.modelPlaneReady
      && activeFixture.resolver.litellm == m.resolver
      && enabled.services.atrium.runtime.reconciler.enable
      && enabled.services.atriumLitellmAdmission.enable
      && enabled.systemd.services.podman-atrium-n03-models.enable
      && enabled.systemd.services.atrium-n03-admission-settings.enable
      && enabled.systemd.services.atrium-n03-model-inputs.enable
      && enabled.systemd.timers.atrium-reconciler.enable
      && enabled.virtualisation.oci-containers.containers.atrium-n03-models.autoStart;
    native-policy-and-registration-keep-no-model-custody = activeFixture.nativePolicy.litellm == null
      && activeFixture.registration.litellm == null;
    unchanged-resolver-default = f.resolver.litellm == null
      && !lib.hasInfix "model-resolver" (lib.concatStringsSep " " c.services.atrium.runtime.resolver.arguments);
    distinct-publisher-and-consumer-uids = builtins.length
      (lib.unique (map (role: role.uid) (builtins.attrValues m.roles))) == 4;
    separate-metadata-token-groups = m.metadataGroup.gid != m.deliveryGroup.gid;
    publisher-and-reader-membership = lib.all includes [
      m.roles.resolver.name
      m.roles.controller.name
      m.roles.gateway.name
    ];
    no-gateway-or-resolver-token-membership =
      !(lib.elem m.deliveryGroup.name c.users.users.${m.roles.gateway.name}.extraGroups)
      && !(lib.elem m.deliveryGroup.name c.users.users.${m.roles.resolver.name}.extraGroups)
      && m.roles.gateway.gid != m.deliveryGroup.gid && m.roles.resolver.gid != m.deliveryGroup.gid;
    whiskey-not-metadata-reader = !includes m.roles.whiskey.name;
    two-separate-publisher-directories = m.exports.resolver != m.exports.controller
      && lib.all
      (directory: directory.mode == "2750" && directory.group == m.metadataGroup.name
        && lib.elem "d ${directory.path} ${directory.mode} ${directory.owner} ${directory.group} -" c.systemd.tmpfiles.rules)
      m.publisherDirectories;
    private-state-not-exported = lib.all
      (path: !(lib.hasPrefix path m.exports.resolver) && !(lib.hasPrefix path m.exports.controller))
      (builtins.attrValues m.private);
    resolver-publication-fields = m.resolver.publication_directory == m.exports.resolver
      && m.resolver.publication_reader_gid == m.metadataGroup.gid;
    controller-publication-fields = m.controller.publication_reader_gid == m.metadataGroup.gid
      && m.controller.bindings_snapshot == "${m.exports.controller}/native-bindings.json"
      && m.controller.service_association_snapshot == "${m.exports.controller}/service-associations.json";
    exact-reader-publisher-uids = m.controller.association_publisher_uid == m.roles.resolver.uid
      && m.resolver.controller_publisher_uid == m.roles.controller.uid
      && (builtins.head m.admission.producers).publisher_uid == m.roles.resolver.uid
      && (builtins.elemAt m.admission.producers 1).publisher_uid == m.roles.controller.uid;
    readers-use-live-exports = m.controller.association_snapshot == "${m.exports.resolver}/associations.json"
      && (builtins.head m.admission.producers).path == "${m.exports.resolver}/admission-associations.json"
      && (builtins.elemAt m.admission.producers 1).path == m.controller.service_association_snapshot;
    public-issuer-preserved = m.resolver.endpoint == f.generated.resolver.deployments.litellm.endpoint
      && m.controller.issuer == m.admission.issuer && m.admission.issuer == m.resolver.endpoint
      && m.admission.issuer == f.whiskeyModel.issuer;
    inference-transport-separate-from-logical-bindings =
      m.inferenceEndpoint == "${f.endpoints.models}/v1/chat/completions"
      && lib.all (id: f.generated.resolver.instances.${id}.target != m.inferenceEndpoint)
        [ "family-models" "personal-models" ]
      && lib.all (id: lib.elem "/v1/chat/completions" f.generated.resolver.model_templates.${id}.routes)
        [ "family-child" "personal-client" ];
    actual-post-auth-and-callback = gateway.environment.LITELLM_WORKER_STARTUP_HOOKS == "atrium_admission.bootstrap:install"
      && m.gateway.litellm_settings.callbacks == [ "atrium_admission.hook.admission" ];
    authoritative-feed-inputs = m.admission.deny_issuer == f.resolver.signing.issuer
      && m.admission.deny_url == "${f.endpoints.resolver}/v1/deny-feed"
      && m.admission.jwks_url == "${f.endpoints.resolver}/.well-known/jwks.json"
      && m.admission.poll_seconds <= 20 && m.admission.fetch_timeout_seconds <= 5;
    actual-pinned-image-startup = gateway.image == f.versions.litellm
      && gateway.entrypoint == "/app/docker/prod_entrypoint.sh"
      && gateway.workdir == m.gatewayWorkingDirectory
      && gateway.cmd == m.gatewayCommand;
    nonroot-capability-free-gateway = gateway.user == "${toString m.roles.gateway.uid}:${toString m.roles.gateway.gid}"
      && lib.elem "--cap-drop=ALL" gateway.extraOptions
      && lib.elem "--security-opt=no-new-privileges" gateway.extraOptions
      && lib.elem "--group-add=${toString m.metadataGroup.gid}" gateway.extraOptions;
    namespace-and-backend-loopback = lib.elem "--network=ns:${f.namespacePath}" gateway.extraOptions
      && lib.elem "127.0.0.1" gateway.cmd && gateway.ports == [ ]
      && c.systemd.services.atrium-reconciler.serviceConfig.NetworkNamespacePath == f.namespacePath;
    gateway-read-only-metadata = lib.all
      (path: lib.elem "${path}:${path}:ro" gateway.volumes)
      (builtins.attrValues m.exports);
    no-publisher-private-or-token-mounts = !(lib.any
      (volume:
        let source = builtins.head (lib.splitString ":" volume); in
        lib.any (path: path == source || lib.hasPrefix "${source}/" path) [
          f.state.resolver
          m.private.resolver
          m.private.controller
          "${f.runtime}/delivery"
          "${f.runtime}/provider-input"
          "${f.runtime}/acknowledgements/whiskey"
        ])
      gateway.volumes);
    secret-references-not-values = gateway.environmentFiles == [ "${f.runtime}-input/gateway-secrets.env" ]
      && !(gateway.environment ? LITELLM_MASTER_KEY) && !(gateway.environment ? DATABASE_URL)
      && m.gateway.general_settings.master_key == "os.environ/LITELLM_MASTER_KEY"
      && m.gateway.general_settings.database_url == "os.environ/DATABASE_URL";
    no-implicit-admission-initialization =
      c.systemd.services.podman-atrium-n03-models.unitConfig.ConditionPathExists
      == "${m.admission.runtime_directory}/initialized";
    current-regular-policy-reference = m.admission.policy_path == m.policyPath
      && m.admission.policy_publisher_uid == 0 && !(lib.hasPrefix "/nix/store" m.policyPath);
    protected-input-copy-modes = m.publicationFileMode == "0640" && m.inputFileMode == "0640"
      && lib.elem "d ${f.runtime}/model-inputs 0750 root ${m.metadataGroup.name} -" c.systemd.tmpfiles.rules
      && lib.hasInfix "install -m 0640 -g ${m.metadataGroup.name}"
      c.systemd.services.atrium-n03-model-inputs.script
      && lib.hasInfix "${f.runtime}-input/front-ca ${f.runtime}/model-inputs/front-ca"
      c.systemd.services.atrium-n03-model-inputs.script
      && gateway.environment.NIX_SSL_CERT_FILE == "${f.runtime}/model-inputs/front-ca"
      && c.systemd.services.atrium-n03-model-inputs.serviceConfig.User == "root"
      && !(lib.hasInfix m.admissionSettingsPath c.systemd.services.atrium-n03-model-inputs.script)
      && c.systemd.services.atrium-n03-model-inputs.serviceConfig.SupplementaryGroups == [ m.metadataGroup.name ];
    settings-owned-by-actual-loader-caller = m.admissionSettingsFileMode == "0600"
      && m.admissionSettingsPath == "${m.private.gateway}/config/admission.json"
      && gateway.environment.ATRIUM_ADMISSION_SETTINGS == m.admissionSettingsPath
      && c.services.atriumLitellmAdmission.settingsFile == m.admissionSettingsPath
      && c.systemd.services.atrium-n03-admission-settings.serviceConfig.User == m.roles.gateway.name
      && c.systemd.services.atrium-n03-admission-settings.serviceConfig.Group == m.roles.gateway.name
      && c.systemd.services.atrium-n03-admission-settings.serviceConfig.CapabilityBoundingSet == [ "" ]
      && lib.elem "d ${m.private.gateway}/config 0700 ${m.roles.gateway.name} ${m.roles.gateway.name} -" c.systemd.tmpfiles.rules
      && lib.hasInfix "install -m 0600" c.systemd.services.atrium-n03-admission-settings.script
      && lib.hasInfix m.admissionSettingsPath c.systemd.services.atrium-n03-admission-settings.script
      && lib.elem "atrium-n03-admission-settings.service" c.systemd.services.podman-atrium-n03-models.requires;
    real-w03-live-delivery = m.delivery.key_path == f.whiskeyModel.key_path
      && m.delivery.acknowledgement_path == f.whiskeyModel.acknowledgement_path
      && m.delivery.key_owner_uid == f.whiskeyModel.key_owner_uid
      && m.delivery.group_id == m.controller.service_delivery.whiskey-service.consumer_gid;
    bounded-fixture-rotation = m.delivery.rotation_interval_seconds == 2
      && m.delivery.overlap_seconds == 5;
    model-route-blocked-by-default = lib.hasInfix "explicit native opt-in required" liveCaddy
      && !(lib.hasInfix m.backend liveCaddy);
    future-route-keeps-native-auth = lib.hasInfix "reverse_proxy ${m.backend}" previewCaddy
      && lib.hasInfix "import native_headers" previewCaddy
      && !(lib.hasInfix "header_up -Authorization" previewCaddy);
    all-new-cases-unexecuted = !cases.runtime_gate_evidence
      && lib.all (row: row.status == "unexecuted") cases.cases;
    valid-module-assertions = lib.all (item: item.assertion) (c.assertions ++ enabled.assertions);
  };
in
assert lib.assertMsg (lib.all (value: value) (builtins.attrValues checks))
  ("N03 model preparation failed: " + builtins.toJSON (lib.filterAttrs (_: value: !value) checks));
{
  inherit checks;
  kind = "atrium.n03-model-source-preparation";
  source_only = true;
  runtime_gate_evidence = false;
  model_plane_ready = false;
  accepted_publisher_pins = {
    inherit (m.acceptedPublisherPins) verified atrium controller catalog uidReceipt modelReceipt;
  };
  check_count = builtins.length (builtins.attrNames checks);
  unexecuted_native_groups = builtins.length cases.cases;
}
