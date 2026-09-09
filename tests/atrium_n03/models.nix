{ lib, ids, runtime, state, registry, generated, endpoints }:
let
  installation = "atrium-n03-isolated";
  port = 14000;
  metadataGroup = {
    name = "atrium-model-metadata-fixture";
    inherit (ids.atrium-model-metadata-fixture) gid;
  };
  deliveryGroup = {
    name = "atrium-consumer-fixture";
    inherit (ids.atrium-consumer-fixture) gid;
  };
  roles = {
    resolver = { name = "atrium-resolver"; inherit (ids.atrium-resolver-fixture) uid gid; };
    controller = { name = "atrium-reconciler"; inherit (ids.atrium-reconciler-fixture) uid gid; };
    gateway = { name = "atrium-model-gateway-fixture"; inherit (ids.atrium-model-gateway-fixture) uid gid; };
    whiskey = { name = "whiskey-whiskey-whiskey"; inherit (ids.atrium-consumer-fixture) uid gid; };
  };
  exports = {
    resolver = "/run/atrium-n03-publications/resolver";
    controller = "/run/atrium-n03-publications/controller";
  };
  private = {
    resolver = "${state.resolver}/models";
    controller = "/var/lib/atrium-reconciler";
    gateway = "/var/lib/atrium-model-gateway";
  };
  policyPath = "${runtime}/model-inputs/policy.json";
  admissionSettingsPath = "${runtime}/model-inputs/admission.json";
  acknowledgementPath = "${runtime}/acknowledgements/whiskey/key.json";
  providers = {
    "personal:ryan" = "http://personal.models.atrium.invalid:8000/v1";
    "family:holt" = "http://family.models.atrium.invalid:8000/v1";
  };
in
{
  inherit installation port metadataGroup deliveryGroup roles exports private policyPath admissionSettingsPath;
  acceptedPublisherPins = null;
  publicationFileMode = "0640";
  inputFileMode = "0640";
  activation = "disabled; accepted publisher pins, source review and native authorization required";
  backend = "http://127.0.0.1:${toString port}";
  issuer = endpoints.models;
  publisherDirectories = [
    { path = exports.resolver; owner = roles.resolver.name; group = metadataGroup.name; mode = "2750"; }
    { path = exports.controller; owner = roles.controller.name; group = metadataGroup.name; mode = "2750"; }
  ];
  resolver = {
    endpoint = endpoints.models;
    inherit installation;
    runtime_directory = private.resolver;
    controller_key_file = "/run/credentials/atrium-resolver.service/model-management";
    controller_inventory_file = "${exports.controller}/native-bindings.json";
    controller_desired_state_path = "/etc/atrium/desired-state/litellm.json";
    controller_publisher_uid = roles.controller.uid;
    publication_directory = exports.resolver;
    publication_reader_gid = metadataGroup.gid;
    maintenance_interval_seconds = 20;
  };
  controller = {
    schema_version = 1;
    environment = "isolated";
    inherit installation;
    issuer = endpoints.models;
    endpoint = "http://127.0.0.1:${toString port}";
    desired_state = "/etc/atrium/desired-state/litellm.json";
    ownership_directory = private.controller;
    association_snapshot = "${exports.resolver}/associations.json";
    association_publisher_uid = roles.resolver.uid;
    publication_reader_gid = metadataGroup.gid;
    bindings_snapshot = "${exports.controller}/native-bindings.json";
    service_association_snapshot = "${exports.controller}/service-associations.json";
    management_key_file = "/run/credentials/atrium-reconciler.service/management";
    backend_transports = lib.mapAttrs
      (_: backend: {
        api_base = providers.${backend.domain};
      })
      registry.modelBackends;
    service_delivery.whiskey-service = {
      ack_path = acknowledgementPath;
      consumer_uid = roles.whiskey.uid;
      consumer_gid = deliveryGroup.gid;
      ack_timeout_seconds = 60;
    };
  };
  admission = {
    schema_version = 1;
    isolated = true;
    inherit installation;
    issuer = endpoints.models;
    runtime_directory = "${private.gateway}/admission";
    policy_path = policyPath;
    policy_publisher_uid = 0;
    producers = [
      {
        id = "resolver";
        kind = "resolver";
        path = "${exports.resolver}/admission-associations.json";
        publisher_uid = roles.resolver.uid;
      }
      {
        id = "controller-services";
        kind = "controller-service";
        path = "${exports.controller}/service-associations.json";
        publisher_uid = roles.controller.uid;
      }
    ];
    deny_issuer = endpoints.resolver;
    deny_url = "${endpoints.resolver}/v1/deny-feed";
    jwks_url = "${endpoints.resolver}/.well-known/jwks.json";
    poll_seconds = 20;
    fetch_timeout_seconds = 5;
  };
  gateway = {
    # N04 creates and verifies owned aliases; static aliases cannot substitute.
    model_list = [ ];
    general_settings = {
      master_key = "os.environ/LITELLM_MASTER_KEY";
      database_url = "os.environ/DATABASE_URL";
      store_model_in_db = true;
      disable_spend_logs = true;
    };
    litellm_settings = {
      cache = true;
      cache_params = { type = "local"; ttl = 60; };
      callbacks = [ "atrium_admission.hook.admission" ];
      set_verbose = false;
      turn_off_message_logging = true;
      success_callback = [ ];
      failure_callback = [ ];
    };
    router_settings = {
      num_retries = 0;
      max_fallbacks = 0;
      fallbacks = [ ];
      context_window_fallbacks = [ ];
      content_policy_fallbacks = [ ];
    };
  };
  gatewayEnvironment = {
    ATRIUM_ADMISSION_SETTINGS = admissionSettingsPath;
    LITELLM_WORKER_STARTUP_HOOKS = "atrium_admission.bootstrap:install";
    LITELLM_LOCAL_MODEL_COST_MAP = "True";
    LITELLM_TELEMETRY = "False";
    DO_NOT_TRACK = "1";
    LITELLM_LOG = "ERROR";
    DISABLE_ADMIN_UI = "True";
    PYTHONDONTWRITEBYTECODE = "1";
    HOME = private.gateway;
    TMPDIR = "${private.gateway}/scratch";
    NIX_SSL_CERT_FILE = "${runtime}/model-inputs/front-ca";
  };
  gatewayCommand = [
    "--config"
    "/etc/atrium/n03/model-gateway.json"
    "--host"
    "127.0.0.1"
    "--port"
    (toString port)
    "--num_workers"
    "2"
  ];
  delivery = {
    key_path = registry.modelTemplates.whiskey-service.service.runtimeKeyPath;
    key_owner_uid = roles.controller.uid;
    acknowledgement_path = acknowledgementPath;
    group = deliveryGroup.name;
    group_id = deliveryGroup.gid;
    token_directory_mode = "2750";
    token_file_mode = "0640";
    acknowledgement_directory_mode = "0750";
    acknowledgement_file_mode = "0640";
    rotation_interval_seconds = generated.resolver.model_templates.whiskey-service.service.rotation_interval_seconds;
    overlap_seconds = generated.resolver.model_templates.whiskey-service.service.overlap_seconds;
    consumer = "Unchanged W03 live-file reader and success-bound acknowledgement; never an environment or LoadCredential token snapshot";
  };
  bootstrap = [
    "Provision only synthetic N07 database/providers and private runtime controls; validate the pinned image and complete immutable payloads before resource startup"
    "Explicitly initialize R01/signing and subordinate grants, then start real R06 as the resolver UID to publish its complete empty/current exports"
    "Explicitly initialize the real N04 Ledger and publish_service_associations under the controller UID; never fabricate an empty ownership document"
    "Copy only current non-secret N02 policy and admission settings to regular root-owned runtime files; initialize N05 history explicitly under the gateway UID"
    "Start the pinned native gateway with actual post-auth bootstrap plus callback; readiness requires native authenticated HTTP, not process liveness"
    "Run actual N04 reconcile under the controller UID, then obtain client keys through real R03/R06 and exercise W03's live key/ack/overlap lifecycle"
  ];
  artifacts = {
    resolverProfiles = "Actual flake exports; no producer code copied from unaccepted worktrees";
    nativeImage = "N07 pins.json LiteLLM1.99.1 manifest/platform/package checks";
    modelWheels = "Existing tests/atrium_n05/supervisor.py verified_wheels; complete controller/admission/profile/resolver source comparison";
    whiskey = "Existing tests/atrium_n03/artifacts.py and build_runtime.py immutable source/compiled member guards";
    orchestration = "Existing N07 Resources/database/provider lifecycle; N03 adds host topology pairs, not a replacement harness";
  };
}
